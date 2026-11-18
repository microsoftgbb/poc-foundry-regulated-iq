import copy
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("native_iq", ROOT / "scripts/native_iq.py")
native_iq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native_iq)

SUBSCRIPTION = "6ab9178f-09bc-45be-ba47-f682147eb1f0"
GROUP = "rg-regiq-caldova-poc"


def domains():
    result = []
    for key, (oid, container) in zip(("a", "b"), native_iq.BINDINGS.items()):
        result.append({
            "officerObjectId": oid,
            "sourceStorage": native_iq.SOURCE_STORAGE,
            "sourceContainer": container,
            "derivedStorage": f"riq{key}test",
            "runtimeStorage": f"rih{key}test",
            "cosmosAccount": f"regiq-{key}-test",
            "searchService": f"regiq-{key}-test",
            "foundryAccount": f"regiq-{key}-test",
            "projectName": "caseiq",
            "searchEndpoint": f"https://regiq-{key}-test.search.windows.net",
            "sourceEndpoint": f"https://{native_iq.SOURCE_STORAGE}.blob.core.windows.net",
            "derivedEndpoint": f"https://riq{key}test.blob.core.windows.net/",
            "consumerAccessEnabled": False,
        })
    return result


class NativeDefinitionsTests(unittest.TestCase):
    def render(self, value=None):
        return native_iq.render(
            {"domains": {"value": value or domains()}}, SUBSCRIPTION, GROUP
        )

    def test_officers_have_distinct_sources_indexes_connections_and_filters(self):
        manifests = self.render()
        for manifest, domain, other in zip(manifests, domains(), reversed(domains())):
            requests = {r["name"]: r for r in manifest["requests"]}
            source = requests["knowledgesources"]["body"]["searchIndexParameters"]
            self.assertIn(domain["officerObjectId"], source["baseFilter"])
            self.assertNotIn(other["officerObjectId"], source["baseFilter"])
            self.assertIn(domain["searchService"], requests["prompt-agent"]["body"]
                          ["definition"]["tools"][0]["server_url"])
            self.assertIn(domain["derivedStorage"],
                          requests["datasources"]["body"]["credentials"]["connectionString"])
            self.assertEqual(requests["datasources"]["body"]["container"]["name"],
                             "approved-content")
            self.assertFalse(manifest["consumerAccessEnabled"])

    def test_rejects_cross_officer_container_and_shared_resources(self):
        value = domains()
        value[0]["sourceContainer"] = value[1]["sourceContainer"]
        with self.assertRaisesRegex(ValueError, "binding"):
            self.render(value)
        for field in ("searchService", "derivedStorage", "runtimeStorage",
                      "cosmosAccount", "foundryAccount"):
            value = domains()
            value[0][field] = value[1][field]
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "share"):
                self.render(value)
        value = domains()
        value[0]["runtimeStorage"] = value[0]["derivedStorage"]
        with self.assertRaisesRegex(ValueError, "separate"):
            self.render(value)

    def test_rejects_unexpected_officers_and_released_consumers(self):
        value = domains()
        value[1]["officerObjectId"] = value[0]["officerObjectId"]
        with self.assertRaisesRegex(ValueError, "exactly"):
            self.render(value)
        value = domains()
        value[0]["consumerAccessEnabled"] = True
        with self.assertRaisesRegex(ValueError, "release"):
            self.render(value)

    def test_rejects_arbitrary_endpoints_before_any_azure_call(self):
        for field in ("searchEndpoint", "sourceEndpoint", "derivedEndpoint"):
            value = domains()
            value[0][field] = "https://example.invalid"
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "match"):
                self.render(value)

    def test_custom_analyzer_precedes_index_and_no_fake_search_skill(self):
        manifest = self.render()[0]
        requests = manifest["requests"]
        self.assertEqual(requests[0]["name"], "cu-model-defaults")
        self.assertEqual(requests[1]["name"], "custom-analyzer")
        self.assertIn("/contentunderstanding/analyzers/", requests[1]["url"])
        self.assertEqual(requests[1]["body"]["baseAnalyzerId"], "prebuilt-document")
        self.assertNotIn("skillsets", {r["name"] for r in requests})
        self.assertEqual(len(manifest["analyzerDefinitionSha256"]), 64)
        changed = copy.deepcopy(requests[1]["body"])
        changed["description"] += " revised"
        self.assertNotEqual(native_iq.canonical_hash(changed),
                            manifest["analyzerDefinitionSha256"])

    def test_native_agent_has_only_read_tool_and_no_hosted_code(self):
        requests = self.render()[0]["requests"]
        connection = next(r["body"] for r in requests if r["name"] == "mcp-connection")
        self.assertFalse(connection["properties"]["isSharedToAll"])
        agent = requests[-1]["body"]["definition"]
        self.assertEqual(agent["kind"], "prompt")
        self.assertNotIn("harness", agent)
        self.assertEqual(len(agent["tools"]), 1)
        self.assertEqual(agent["tools"][0]["allowed_tools"],
                         {"tool_names": ["knowledge_base_retrieve"]})
        self.assertNotIn("headers", agent["tools"][0])

    def test_private_indexer_fails_closed_and_has_no_unapproved_source(self):
        requests = {r["name"]: r for r in self.render()[0]["requests"]}
        indexer = requests["indexers"]["body"]
        self.assertEqual(indexer["parameters"]["configuration"]["executionEnvironment"],
                         "private")
        self.assertEqual(indexer["parameters"]["maxFailedItems"], 0)
        self.assertNotIn("schedule", indexer)
        fields = {f["name"] for f in requests["indexes"]["body"]["fields"]}
        self.assertTrue({"source_version", "source_sha256", "analysis_sha256",
                         "analyzer_version", "officer_oid", "approval_id"} <= fields)


if __name__ == "__main__":
    unittest.main()
