#!/usr/bin/env python3
"""Configure private native services from a VNet-connected administrative client."""

import argparse
import ipaddress
import json
import socket
import subprocess
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

from native_iq import CU_API, render


TENANT = "95287129-9bbb-4084-8485-dc845ae7d143"
SUBSCRIPTION = "6ab9178f-09bc-45be-ba47-f682147eb1f0"
GROUP = "rg-regiq-caldova-poc"
PRIVATE_RANGES = tuple(ipaddress.ip_network(cidr) for cidr in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
))


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def require_private_dns(host):
    addresses = {entry[4][0] for entry in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)}
    if not addresses or any(
        not any(ipaddress.ip_address(value) in network for network in PRIVATE_RANGES)
        for value in addresses
    ):
        raise ValueError(f"{host} does not resolve exclusively to private addresses. "
                         "Use a VNet-connected client; public access will not be enabled.")


def credential_scope(parsed):
    service = "contentunderstanding" if parsed.path.startswith("/contentunderstanding/") else "service"
    return parsed.hostname, service


class AzureClient:
    def __init__(self, requests):
        self.audiences = {}
        for request in requests:
            scope = credential_scope(urlparse(request["url"]))
            audience = request["audience"]
            if scope in self.audiences and self.audiences[scope] != audience:
                raise ValueError("Inconsistent Azure token audience.")
            self.audiences[scope] = audience
        self.opener = build_opener(NoRedirect())

    def preflight(self):
        context = json.loads(subprocess.run(
            ["az", "account", "show", "--subscription", SUBSCRIPTION, "-o", "json"],
            check=True, capture_output=True, text=True,
        ).stdout)
        if context["tenantId"] != TENANT:
            raise ValueError("Azure CLI is not authenticated to the Caldova directory.")
        for host in {host for host, _ in self.audiences}:
            if host != "management.azure.com":
                require_private_dns(host)

    def request(self, method, url, body=None, *, allow_not_found=False):
        parsed = urlparse(url)
        scope = credential_scope(parsed)
        if (
            parsed.scheme != "https" or scope not in self.audiences
            or parsed.username or parsed.password or parsed.port not in (None, 443)
        ):
            raise ValueError("Refusing to send Azure credentials to an unexpected endpoint.")
        token = subprocess.run(
            ["az", "account", "get-access-token", "--subscription", SUBSCRIPTION,
             "--resource", self.audiences[scope], "--query", "accessToken",
             "-o", "tsv"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        if not token:
            raise ValueError("Azure CLI returned an empty access token.")
        request = Request(url, method=method, headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }, data=None if body is None else json.dumps(body).encode())
        try:
            with self.opener.open(request, timeout=60) as response:
                raw = response.read(16 * 1024 * 1024 + 1)
                if len(raw) > 16 * 1024 * 1024:
                    raise ValueError("Azure service response exceeded the configuration limit.")
                return response.status, response.headers, json.loads(raw) if raw else {}
        except HTTPError as exc:
            code = exc.code
            request_id = exc.headers.get("x-ms-request-id", "unavailable")
            exc.close()
            if allow_not_found and method == "GET" and code == 404:
                return 404, {}, {}
            raise RuntimeError(
                f"Azure {parsed.hostname} returned HTTP {code}; "
                f"request ID {request_id}."
            ) from None
        except URLError as exc:
            raise RuntimeError(f"Azure {parsed.hostname} connection failed: {exc.reason}") from None

    def execute(self, request):
        status, headers, body = self.request(request["method"], request["url"], request["body"])
        operation = headers.get("Operation-Location")
        if status == 202 and not operation:
            raise RuntimeError("Azure accepted an operation without a pollable operation URL.")
        if (
            request["name"] == "custom-analyzer" and not operation
            and body.get("status", "").lower() not in ("succeeded", "ready")
        ):
            raise RuntimeError("Analyzer creation was neither completed nor pollable.")
        if operation:
            origin = urlparse(request["url"])
            target = urlparse(operation)
            if (
                target.scheme != "https" or target.netloc != origin.netloc
                or not target.path.startswith("/contentunderstanding/")
            ):
                raise ValueError("Refusing an unexpected asynchronous operation location.")
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                _, _, body = self.request("GET", operation)
                state = body.get("status", "").lower()
                if state == "succeeded":
                    break
                if state not in ("running", "notstarted"):
                    raise RuntimeError(f"Azure asynchronous operation failed; state={state!r}.")
                time.sleep(3)
            else:
                raise TimeoutError("Azure asynchronous configuration operation timed out.")
        if (
            request["name"] == "prompt-agent"
            and not body.get("versions", {}).get("latest", {}).get("version")
        ):
            raise RuntimeError("Agent creation response did not contain a latest version.")
        return body


def assert_expected_configuration(expected, actual):
    if isinstance(expected, dict):
        if not isinstance(actual, dict) or not expected.keys() <= actual.keys():
            raise ValueError("Existing native configuration is missing expected fields.")
        for key, value in expected.items():
            assert_expected_configuration(value, actual[key])
    elif isinstance(expected, list):
        if not isinstance(actual, list) or len(expected) != len(actual):
            raise ValueError("Existing native configuration has an unexpected array.")
        for left, right in zip(expected, actual):
            assert_expected_configuration(left, right)
    elif type(expected) is not type(actual) or expected != actual:
        raise ValueError("Existing native configuration differs from the intended definition.")


def ensure_definition(client, request):
    if request["name"] in ("custom-analyzer", "prompt-agent"):
        url = request["url"]
        if request["name"] == "prompt-agent":
            url = url.replace("/agents?", f"/agents/{request['body']['name']}?")
        status, _, existing = client.request("GET", url, allow_not_found=True)
        if status != 404:
            if request["name"] == "prompt-agent":
                latest = existing.get("versions", {}).get("latest", {})
                if not latest.get("version"):
                    raise ValueError("Existing agent has no latest version.")
                assert_expected_configuration(request["body"]["definition"],
                                              latest.get("definition"))
            else:
                assert_expected_configuration(request["body"], existing)
                if existing.get("status", "").lower() != "ready":
                    raise ValueError("Existing analyzer is not ready.")
            return existing
    return client.execute(request)


def verify_runtime_bindings(client, manifest):
    connection = next(r for r in manifest["requests"] if r["name"] == "mcp-connection")
    project = connection["url"].rsplit("/connections/", 1)[0]
    _, _, host = client.request(
        "GET", f"{project}/capabilityHosts/caseiq?api-version=2025-06-01"
    )
    properties = host.get("properties", {})
    if properties.get("provisioningState") != "Succeeded":
        raise ValueError("Native BYO project capability host is not ready.")
    for field, binding in manifest["runtimeBindings"].items():
        name = binding["name"]
        if properties.get(field) != [name]:
            raise ValueError(f"Native BYO host has an unexpected {field} binding.")
        _, _, connection = client.request(
            "GET", f"{project}/connections/{name}?api-version=2025-10-01-preview"
        )
        actual = connection.get("properties", {})
        if (
            actual.get("authType") != "AAD"
            or actual.get("useWorkspaceManagedIdentity") is not True
            or actual.get("category") != binding["category"]
            or actual.get("target", "").rstrip("/") != binding["target"].rstrip("/")
            or actual.get("metadata", {}).get("ResourceId", "").lower() != binding["resourceId"].lower()
        ):
            raise ValueError(f"Native BYO connection {name} does not match its isolated store.")


def apply(manifests):
    requests = [request for manifest in manifests for request in manifest["requests"]]
    client = AzureClient(requests)
    client.preflight()
    for manifest in manifests:
        verify_runtime_bindings(client, manifest)
    for manifest in manifests:
        analyzer = next(r for r in manifest["requests"] if r["name"] == "custom-analyzer")
        endpoint = analyzer["url"].split("/contentunderstanding/")[0]
        _, _, base = client.request(
            "GET", f"{endpoint}/contentunderstanding/analyzers/prebuilt-document?api-version={CU_API}"
        )
        for kind, model in analyzer["body"]["models"].items():
            if model not in base.get("supportedModels", {}).get(kind, []):
                raise ValueError(f"Content Understanding base analyzer does not advertise {kind} model {model}.")
        for request in manifest["requests"]:
            ensure_definition(client, request)
            print(f"Configured {manifest['officerObjectId']}: {request['name']}")
    print("Native definitions configured. Officer access and Teams publishing remain disabled.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--outputs", type=Path, required=True)
    parser.add_argument("--apply", action="store_true",
                        help="Perform Azure writes. Default only checks/renders the definitions.")
    args = parser.parse_args()
    try:
        manifests = render(json.loads(args.outputs.read_text()), SUBSCRIPTION, GROUP)
        if args.apply:
            apply(manifests)
        else:
            print(json.dumps(manifests, indent=2))
    except (ValueError, KeyError, TypeError, RuntimeError, TimeoutError,
            subprocess.CalledProcessError, OSError) as exc:
        parser.exit(1, f"Native IQ configuration failed: {exc}\n")


if __name__ == "__main__":
    main()
