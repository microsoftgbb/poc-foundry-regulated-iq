#!/usr/bin/env python3
"""Render native Azure service definitions; not an officer-facing application."""

import argparse
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
# Option A officer domains come from the single officer registry.
BINDINGS = {
    officer["objectId"]: officer["container"]
    for officer in json.loads((ROOT / "infra/officers.json").read_text())["officers"]
    if officer.get("optionA")
}
SOURCE_STORAGE = "regiqvqx35xnseaqaw"
SEARCH_API = "2026-08-01-preview"
CU_API = "2025-11-01"


def canonical_hash(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    ).hexdigest()


def validate_domain(domain):
    officer = domain["officerObjectId"]
    if domain["sourceContainer"] != BINDINGS.get(officer):
        raise ValueError("Officer/source-container binding does not match the pilot.")
    if domain["sourceStorage"] != SOURCE_STORAGE:
        raise ValueError("Unrecognized pilot source account.")
    if domain.get("consumerAccessEnabled") is not False:
        raise ValueError("Consumer release is not authorized by this configuration.")
    for field in ("searchService", "derivedStorage", "runtimeStorage",
                  "cosmosAccount", "foundryAccount"):
        if not re.fullmatch(r"[a-z][a-z0-9-]{2,62}", domain[field]):
            raise ValueError(f"Invalid or missing {field}; deploy the native domain first.")
    if domain["runtimeStorage"] in (domain["derivedStorage"], domain["sourceStorage"]):
        raise ValueError("Runtime storage must be separate from evidence and source storage.")
    if domain["projectName"] != "caseiq":
        raise ValueError("Unrecognized pilot project.")
    expected = {
        "searchEndpoint": f"https://{domain['searchService']}.search.windows.net",
        "sourceEndpoint": f"https://{SOURCE_STORAGE}.blob.core.windows.net",
        "derivedEndpoint": f"https://{domain['derivedStorage']}.blob.core.windows.net",
    }
    for field, url in expected.items():
        if domain[field].rstrip("/") != url:
            raise ValueError(f"{field} does not match its Azure resource.")


def service_definitions(domain, subscription, resource_group, model="case-chat"):
    validate_domain(domain)
    if not re.fullmatch(r"[a-f0-9-]{36}", subscription):
        raise ValueError("Invalid subscription ID.")
    if not re.fullmatch(r"[\w.()-]{1,90}", resource_group, flags=re.ASCII):
        raise ValueError("Invalid resource group name.")
    search = domain["searchEndpoint"].rstrip("/")
    foundry = f"https://{domain['foundryAccount']}.services.ai.azure.com"
    project = (
        f"https://{domain['foundryAccount']}.services.ai.azure.com"
        f"/api/projects/{domain['projectName']}"
    )
    project_id = (
        f"/subscriptions/{subscription}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{domain['foundryAccount']}"
        f"/projects/{domain['projectName']}"
    )
    resource_prefix = f"/subscriptions/{subscription}/resourceGroups/{resource_group}/providers"
    mcp = f"{search}/knowledgebases/case-evidence/mcp?api-version={SEARCH_API}"
    analyzer = json.loads((ROOT / "native/analyzer.json").read_text())
    analyzer_id = f"case_evidence_{canonical_hash(analyzer)[:16]}"
    fields = [
        {"name": "id", "type": "Edm.String", "key": True, "filterable": True},
        {"name": "title", "type": "Edm.String", "searchable": True},
        {"name": "content", "type": "Edm.String", "searchable": True},
    ]
    for name in (
        "officer_oid", "source_uri", "source_version", "source_sha256",
        "analyzer_version", "analysis_sha256", "approval_id",
    ):
        fields.append({"name": name, "type": "Edm.String", "filterable": True})
    for name in ("page_start", "page_end"):
        fields.append({"name": name, "type": "Edm.Int32", "filterable": True})
    fields.append({"name": "approved", "type": "Edm.Boolean", "filterable": True})
    index = {
        "name": "case-evidence",
        "fields": fields,
        "semantic": {
            "defaultConfiguration": "case-semantic",
            "configurations": [{
                "name": "case-semantic",
                "prioritizedFields": {
                    "titleField": {"fieldName": "title"},
                    "prioritizedContentFields": [{"fieldName": "content"}],
                },
            }],
        },
    }
    source = {
        "name": "approved-case-evidence",
        "kind": "searchIndex",
        "searchIndexParameters": {
            "searchIndexName": index["name"],
            "baseFilter": f"approved eq true and officer_oid eq '{domain['officerObjectId']}'",
            "sourceDataFields": [{"name": field} for field in (
                "title", "content", "source_uri", "source_version", "source_sha256",
                "analyzer_version", "page_start", "page_end", "approval_id",
            )],
        },
    }
    kb = {
        "name": "case-evidence",
        "description": "Independently approved evidence for one isolated officer.",
        "knowledgeSources": [{"name": source["name"]}],
        "outputMode": "extractiveData",
        "retrievalReasoningEffort": {"kind": "minimal"},
    }
    connection = {
        "name": "case-evidence",
        "properties": {
            "authType": "ProjectManagedIdentity",
            "category": "RemoteTool",
            "target": mcp,
            "isSharedToAll": False,
            "audience": "https://search.azure.com/",
            "metadata": {"ApiType": "Azure"},
        },
    }
    agent = {
        "name": "caseiq",
        "definition": {
            "kind": "prompt",
            "model": model,
            "instructions": (ROOT / "native/agent-instructions.txt").read_text().strip(),
            "tools": [{
                "type": "mcp",
                "server_label": "case-evidence",
                "server_url": mcp,
                "require_approval": "never",
                "allowed_tools": {"tool_names": ["knowledge_base_retrieve"]},
                "project_connection_id": "case-evidence",
            }],
        },
    }
    datasource = {
        "name": "approved-content",
        "type": "azureblob",
        "credentials": {"connectionString": (
            f"ResourceId=/subscriptions/{subscription}/resourceGroups/{resource_group}"
            f"/providers/Microsoft.Storage/storageAccounts/{domain['derivedStorage']};"
        )},
        "container": {"name": "approved-content"},
    }
    indexer = {
        "name": "approved-content",
        "dataSourceName": datasource["name"],
        "targetIndexName": index["name"],
        "parameters": {
            "maxFailedItems": 0,
            "maxFailedItemsPerBatch": 0,
            "configuration": {
                "parsingMode": "jsonArray",
                "executionEnvironment": "private",
                "indexedFileNameExtensions": ".json",
            },
        },
    }
    requests = []

    def add(name, method, url, audience, body):
        requests.append({
            "name": name, "method": method, "url": url,
            "audience": audience, "body": body,
        })

    add("cu-model-defaults", "PATCH",
        f"{foundry}/contentunderstanding/defaults?api-version={CU_API}",
        "https://cognitiveservices.azure.com/", {
            "modelDeployments": {
                "gpt-5.1": model,
                "text-embedding-3-small": "case-embedding",
            },
        })
    add("custom-analyzer", "PUT",
        f"{foundry}/contentunderstanding/analyzers/{analyzer_id}?api-version={CU_API}",
        "https://cognitiveservices.azure.com/", analyzer)
    for category, name, body in (
        ("indexes", index["name"], index),
        ("datasources", datasource["name"], datasource),
        ("indexers", indexer["name"], indexer),
        ("knowledgesources", source["name"], source),
        ("knowledgebases", kb["name"], kb),
    ):
        add(category, "PUT", f"{search}/{category}/{name}?api-version={SEARCH_API}",
            "https://search.azure.com/", body)
    add("mcp-connection", "PUT",
        f"https://management.azure.com{project_id}/connections/case-evidence?api-version=2025-10-01-preview",
        "https://management.azure.com/", connection)
    add("prompt-agent", "POST", f"{project}/agents?api-version=v1",
        "https://ai.azure.com/", agent)
    return {
        "officerObjectId": domain["officerObjectId"],
        "analyzerId": analyzer_id,
        "analyzerDefinitionSha256": canonical_hash(analyzer),
        "consumerAccessEnabled": False,
        "runtimeBindings": {
            "storageConnections": {
                "name": "runtime-files", "category": "AzureStorageAccount",
                "target": f"https://{domain['runtimeStorage']}.blob.core.windows.net/",
                "resourceId": f"{resource_prefix}/Microsoft.Storage/storageAccounts/{domain['runtimeStorage']}",
            },
            "threadStorageConnections": {
                "name": "runtime-state", "category": "CosmosDb",
                "target": f"https://{domain['cosmosAccount']}.documents.azure.com:443/",
                "resourceId": f"{resource_prefix}/Microsoft.DocumentDB/databaseAccounts/{domain['cosmosAccount']}",
            },
            "vectorStoreConnections": {
                "name": "runtime-vectors", "category": "CognitiveSearch",
                "target": search,
                "resourceId": f"{resource_prefix}/Microsoft.Search/searchServices/{domain['searchService']}",
            },
        },
        "requests": requests,
    }


def render(outputs, subscription, resource_group):
    domains = outputs["domains"]["value"]
    if len(domains) != 2 or {d["officerObjectId"] for d in domains} != set(BINDINGS):
        raise ValueError("The pilot must contain exactly the two selected officers.")
    for field in ("searchService", "derivedStorage", "runtimeStorage",
                  "cosmosAccount", "foundryAccount"):
        if len({d[field] for d in domains}) != len(domains):
            raise ValueError(f"Officers cannot share {field}.")
    return [service_definitions(d, subscription, resource_group) for d in domains]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--outputs", type=Path, required=True,
                        help="ARM properties.outputs JSON from native-iq.")
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        manifest = render(json.loads(args.outputs.read_text()),
                          args.subscription, args.resource_group)
    except (ValueError, KeyError, TypeError) as exc:
        parser.error(str(exc))
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Rendered {len(manifest)} isolated native domains; no Azure writes performed.")


if __name__ == "__main__":
    main()
