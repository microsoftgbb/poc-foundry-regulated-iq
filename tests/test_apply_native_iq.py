import sys
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import apply_native_iq as apply_iq
from test_native_iq import domains


class ConfigurationClientTests(unittest.TestCase):
    def setUp(self):
        self.request = {
            "name": "custom-analyzer", "method": "PUT",
            "url": "https://regiq-a-test.cognitiveservices.azure.com/contentunderstanding/analyzers/test?api-version=2025-11-01",
            "audience": "https://cognitiveservices.azure.com/", "body": {},
        }
        self.client = apply_iq.AzureClient([self.request])

    def test_public_or_mixed_dns_is_rejected(self):
        for addresses in (["20.1.1.1"], ["10.82.1.4", "20.1.1.1"], ["127.0.0.1"], ["::1"]):
            entries = [(None, None, None, None, (value, 443)) for value in addresses]
            with self.subTest(addresses=addresses), patch.object(
                apply_iq.socket, "getaddrinfo", return_value=entries
            ), self.assertRaisesRegex(ValueError, "private"):
                apply_iq.require_private_dns("test")

    def test_private_dns_is_accepted(self):
        with patch.object(apply_iq.socket, "getaddrinfo", return_value=[
            (None, None, None, None, ("10.82.1.4", 443)),
        ]):
            apply_iq.require_private_dns("test")

    def test_wrong_host_port_or_protocol_never_acquires_token(self):
        for url in (
            "https://example.invalid/", "http://regiq-a-test.cognitiveservices.azure.com/",
            "https://regiq-a-test.cognitiveservices.azure.com:8443/",
            "https://user@regiq-a-test.cognitiveservices.azure.com/",
        ):
            with self.subTest(url=url), patch.object(apply_iq.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "unexpected endpoint"):
                    self.client.request("GET", url)
                run.assert_not_called()

    def test_creation_polls_until_succeeded(self):
        operation = "https://regiq-a-test.cognitiveservices.azure.com/contentunderstanding/operations/test"
        with patch.object(self.client, "request", side_effect=[
            (201, {"Operation-Location": operation}, {}),
            (200, {}, {"status": "Running"}),
            (200, {}, {"status": "Succeeded"}),
        ]) as request, patch.object(apply_iq.time, "sleep"):
            result = self.client.execute(self.request)
        self.assertEqual(result["status"], "Succeeded")
        self.assertEqual(request.call_count, 3)

    def test_shared_foundry_host_uses_each_apis_own_audience(self):
        endpoint = "https://regiq-a-test.services.ai.azure.com"
        analyzer = {**self.request, "url": endpoint + "/contentunderstanding/analyzers/test"}
        agent = {
            **self.request, "name": "prompt-agent",
            "url": endpoint + "/api/projects/caseiq/agents",
            "audience": "https://ai.azure.com/",
        }
        client = apply_iq.AzureClient([analyzer, agent])
        token = type("Result", (), {"stdout": "secret-token"})()
        with patch.object(apply_iq.subprocess, "run", return_value=token) as run, \
                patch.object(client.opener, "open") as open_request:
            response = open_request.return_value.__enter__.return_value
            response.status, response.headers = 200, {}
            response.read.return_value = b"{}"
            for request in (analyzer, agent):
                client.request("GET", request["url"])
                command = run.call_args.args[0]
                self.assertEqual(command[command.index("--resource") + 1],
                                 request["audience"])

    def test_foreign_operation_failed_creation_or_unpollable_acceptance_fails(self):
        for response in (
            (201, {"Operation-Location": "https://example.invalid/token"}, {}),
            (201, {"Operation-Location": "http://regiq-a-test.cognitiveservices.azure.com/contentunderstanding/op"}, {}),
            (202, {}, {}),
            (201, {}, {}),
        ):
            with self.subTest(response=response), patch.object(
                self.client, "request", return_value=response
            ), self.assertRaises((ValueError, RuntimeError)):
                self.client.execute(self.request)
        operation = "https://regiq-a-test.cognitiveservices.azure.com/contentunderstanding/operations/test"
        with patch.object(self.client, "request", side_effect=[
            (201, {"Operation-Location": operation}, {}),
            (200, {}, {"status": "Failed", "error": {"message": "sensitive-document"}}),
        ]), self.assertRaisesRegex(RuntimeError, "state='failed'") as error:
            self.client.execute(self.request)
        self.assertNotIn("sensitive-document", str(error.exception))

    def test_http_failure_does_not_log_body_or_bearer_token(self):
        token = type("Result", (), {"stdout": "secret-token"})()
        error = HTTPError(self.request["url"], 403, "denied", {"x-ms-request-id": "r1"}, None)
        with patch.object(apply_iq.subprocess, "run", return_value=token), patch.object(
            self.client.opener, "open", side_effect=error
        ), self.assertRaisesRegex(RuntimeError, "HTTP 403") as raised:
            self.client.request("GET", self.request["url"])
        self.assertNotIn("secret-token", str(raised.exception))

    def test_not_found_is_allowed_only_for_explicit_definition_reads(self):
        token = type("Result", (), {"stdout": "secret-token"})()
        for method, allow in (("GET", True), ("GET", False), ("POST", True)):
            error = HTTPError(self.request["url"], 404, "absent", {}, None)
            with self.subTest(method=method, allow=allow), patch.object(
                apply_iq.subprocess, "run", return_value=token
            ), patch.object(self.client.opener, "open", side_effect=error):
                if method == "GET" and allow:
                    self.assertEqual(self.client.request(
                        method, self.request["url"], allow_not_found=allow
                    )[0], 404)
                else:
                    with self.assertRaisesRegex(RuntimeError, "HTTP 404"):
                        self.client.request(method, self.request["url"], allow_not_found=allow)

    def test_redirect_is_never_followed(self):
        self.assertIsNone(apply_iq.NoRedirect().redirect_request(
            None, None, 302, "", {}, "https://example.invalid"
        ))

    def test_agent_creation_requires_the_agent_objects_latest_version(self):
        request = {**self.request, "name": "prompt-agent"}
        valid = {"versions": {"latest": {"version": "1"}}}
        with patch.object(self.client, "request", return_value=(200, {}, valid)):
            self.assertEqual(self.client.execute(request), valid)
        for body in ({}, {"version": "1"}, {"versions": {"latest": {}}}):
            with self.subTest(body=body), patch.object(
                self.client, "request", return_value=(200, {}, body)
            ), self.assertRaisesRegex(RuntimeError, "latest version"):
                self.client.execute(request)

    def test_existing_analyzer_is_verified_without_recreating_it(self):
        existing = {"status": "ready", "models": {"completion": "gpt-5.1"}}
        request = {**self.request, "body": {"models": {"completion": "gpt-5.1"}}}
        with patch.object(self.client, "request", return_value=(200, {}, existing)), \
                patch.object(self.client, "execute") as execute:
            self.assertEqual(apply_iq.ensure_definition(self.client, request), existing)
        execute.assert_not_called()
        for body in ({"status": "creating", "models": request["body"]["models"]},
                     {"status": "ready", "models": {"completion": "other"}}):
            with self.subTest(body=body), patch.object(
                self.client, "request", return_value=(200, {}, body)
            ), patch.object(self.client, "execute") as execute, self.assertRaises(ValueError):
                apply_iq.ensure_definition(self.client, request)
            execute.assert_not_called()
        with patch.object(self.client, "request", return_value=(404, {}, {})), \
                patch.object(self.client, "execute") as execute:
            apply_iq.ensure_definition(self.client, request)
        execute.assert_called_once_with(request)

    def test_existing_agent_definition_is_verified_before_reuse(self):
        definition = {"kind": "prompt", "model": "case-chat", "tools": [{"type": "mcp"}]}
        request = {**self.request, "name": "prompt-agent",
                   "url": "https://regiq-a-test.services.ai.azure.com/api/projects/caseiq/agents?api-version=v1",
                   "body": {"name": "caseiq", "definition": definition}}
        existing = {"versions": {"latest": {"version": "1", "definition": definition}}}
        with patch.object(self.client, "request", return_value=(200, {}, existing)) as read, \
                patch.object(self.client, "execute") as execute:
            apply_iq.ensure_definition(self.client, request)
        self.assertIn("/agents/caseiq?", read.call_args.args[1])
        execute.assert_not_called()
        for actual in ({**definition, "model": "other"},
                       {**definition, "tools": [{"type": "mcp"}, {"type": "extra"}]}):
            with self.subTest(actual=actual), self.assertRaises(ValueError):
                apply_iq.assert_expected_configuration(definition, actual)

    def test_native_byo_bindings_must_match_live_host_and_connections(self):
        manifest = apply_iq.render(
            {"domains": {"value": domains()}}, apply_iq.SUBSCRIPTION, apply_iq.GROUP
        )[0]
        bindings = manifest["runtimeBindings"]
        host = {
            "properties": {
                "provisioningState": "Succeeded",
                **{field: [binding["name"]] for field, binding in bindings.items()},
            },
        }
        connections = [{
            "properties": {
                "authType": "AAD", "category": binding["category"],
                "useWorkspaceManagedIdentity": True,
                "target": binding["target"],
                "metadata": {"ResourceId": binding["resourceId"]},
            },
        } for binding in bindings.values()]
        with patch.object(self.client, "request", side_effect=[
            (200, {}, body) for body in [host, *connections]
        ]) as request:
            apply_iq.verify_runtime_bindings(self.client, manifest)
        self.assertEqual(request.call_count, 4)
        for bad in ({}, {"properties": {"provisioningState": "Creating"}}, {
            "properties": {**host["properties"], "storageConnections": ["other-officer"]},
        }):
            with self.subTest(host=bad), patch.object(
                self.client, "request", return_value=(200, {}, bad)
            ), self.assertRaisesRegex(ValueError, "BYO"):
                apply_iq.verify_runtime_bindings(self.client, manifest)
        for field, wrong in (
            ("authType", "ApiKey"), ("category", "RemoteTool"),
            ("useWorkspaceManagedIdentity", False),
            ("target", "https://other-officer.blob.core.windows.net"),
            ("metadata", {"ResourceId": "/other-officer"}),
        ):
            bad = {"properties": {**connections[0]["properties"], field: wrong}}
            with self.subTest(field=field), patch.object(self.client, "request", side_effect=[
                (200, {}, host), (200, {}, bad),
            ]), self.assertRaisesRegex(ValueError, "isolated store"):
                apply_iq.verify_runtime_bindings(self.client, manifest)

    def test_all_byo_domains_are_checked_before_any_configuration_write(self):
        manifests = apply_iq.render(
            {"domains": {"value": domains()}}, apply_iq.SUBSCRIPTION, apply_iq.GROUP
        )
        with patch.object(apply_iq, "AzureClient") as client, patch.object(
            apply_iq, "verify_runtime_bindings",
            side_effect=[None, ValueError("Second domain has no BYO host")],
        ), self.assertRaisesRegex(ValueError, "Second domain"):
            apply_iq.apply(manifests)
        client.return_value.execute.assert_not_called()
        client.return_value.request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
