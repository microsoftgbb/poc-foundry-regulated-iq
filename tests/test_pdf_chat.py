import io
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from unittest.mock import Mock

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from pypdf import PdfWriter
from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parents[1] / "app"))
from auth import Authentication
from core import Denied, InvalidDocument, Ledger, Officer, StaleDocument, extract_pages, retrieve, verified_source
from pdf_extract import extract


def synthetic_pdf(text="SYNTHETIC FEIN 00-1234567. Tax payment is 7319 dollars."):
    writer = PdfWriter()
    page = writer.add_blank_page(width=612, height=792)
    font = DictionaryObject({
        NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"),
        NameObject("/BaseFont"): NameObject("/Helvetica"),
    })
    page[NameObject("/Resources")] = DictionaryObject({
        NameObject("/Font"): DictionaryObject({NameObject("/F1"): writer._add_object(font)}),
    })
    stream = DecodedStreamObject()
    escaped = text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    stream.set_data(f"BT /F1 12 Tf 50 700 Td ({escaped}) Tj ET".encode())
    page[NameObject("/Contents")] = writer._add_object(stream)
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


class FakeBlobs:
    def __init__(self, content, etag="v1"):
        self.content, self.etag = content, etag

    def read(self, name, expected_etag=None):
        if expected_etag and expected_etag != self.etag:
            raise StaleDocument("Changed version")
        return self.content, self.etag


class DocumentBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ledger = Ledger(str(Path(self.directory.name) / "ledger.sqlite3"))
        self.a = Officer("officer-a", "a", "a-container")
        self.b = Officer("officer-b", "b", "b-container")
        self.content = synthetic_pdf()

    def submit(self):
        return self.ledger.submit(self.a, "tax.pdf", self.content, "v1")

    def approve(self, row):
        self.ledger.approve(row["id"], row["sha256"], "independent-approver", True)

    def test_synthetic_pdf_extraction_runs_in_bounded_subprocess(self):
        self.assertIn("7319", extract_pages(self.content)[0])

    def test_real_fein_and_unmarked_or_malformed_pdf_are_rejected(self):
        for content in [b"not pdf", synthetic_pdf("FEIN 00-1234567"),
                        synthetic_pdf("SYNTHETIC FEIN 12-1234567")]:
            with self.subTest(content=content[:5]), self.assertRaises((ValueError, InvalidDocument)):
                extract(content)

    def test_pending_document_cannot_be_retrieved(self):
        row = self.submit()
        with self.assertRaises(Denied):
            self.ledger.approved(self.a, row["id"])
        self.assertEqual(retrieve(self.ledger, self.a, FakeBlobs(self.content), "tax payment"), [])

    def test_self_approval_and_wrong_hash_are_rejected(self):
        row = self.submit()
        with self.assertRaises(Denied):
            self.ledger.approve(row["id"], row["sha256"], self.a.oid, True)
        with self.assertRaises(StaleDocument):
            self.ledger.approve(row["id"], "0" * 64, "approver", True)

    def test_cross_officer_id_and_passages_are_denied(self):
        row = self.submit()
        self.approve(row)
        with self.assertRaises(Denied):
            self.ledger.approved(self.b, row["id"])
        self.assertEqual(retrieve(self.ledger, self.b, FakeBlobs(self.content), "tax payment"), [])
        passages = retrieve(self.ledger, self.a, FakeBlobs(self.content), "tax payment")
        self.assertIn("7319", passages[0]["text"])

    def test_version_change_and_content_tampering_invalidate_access(self):
        row = self.submit()
        self.approve(row)
        for blobs in [FakeBlobs(self.content, "v2"), FakeBlobs(synthetic_pdf("SYNTHETIC FEIN 00-1234567 changed"))]:
            with self.subTest(etag=blobs.etag), self.assertRaises(StaleDocument):
                verified_source(row, blobs)

    def test_duplicate_submission_preserves_approval_but_new_version_resets_it(self):
        row = self.submit()
        self.approve(row)
        duplicate = self.submit()
        self.assertEqual(duplicate["status"], "approved")
        self.assertEqual(duplicate["id"], row["id"])
        changed = self.ledger.submit(self.a, "tax.pdf", self.content, "v2")
        self.assertEqual(changed["status"], "pending")
        self.assertIsNone(changed["approver"])

    def test_rejection_revokes_retrieval_and_citation_lookup(self):
        row = self.submit()
        self.approve(row)
        self.ledger.approve(row["id"], row["sha256"], "approver", False)
        with self.assertRaises(Denied):
            self.ledger.approved(self.a, row["id"])

    def test_oversized_pdf_is_rejected_before_parser_execution(self):
        with patch("core.subprocess.run") as parser, self.assertRaises(InvalidDocument):
            extract_pages(b"x" * (20 * 1024**2 + 1))
        parser.assert_not_called()


class SignedIdentityFixture:
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def setUp(self):
        self.auth = Authentication("tenant", "app", "bot", {
            "a": {"partition": "a", "container": "a-container"},
        }, ["approver"])
        signing_key = SimpleNamespace(key=self.key.public_key(), _jwk_data={"endorsements": ["msteams"]})
        self.auth.entra_keys = SimpleNamespace(get_signing_key_from_jwt=lambda token: signing_key)
        self.auth.bot_keys = SimpleNamespace(get_signing_key_from_jwt=lambda token: signing_key)

    def token(self, **overrides):
        claims = {
            "iss": "https://login.microsoftonline.com/tenant/v2.0", "tid": "tenant",
            "aud": "app", "oid": "a", "nbf": int(time.time()) - 2,
            "exp": int(time.time()) + 600, "scp": "access_as_user",
        }
        claims.update(overrides)
        return jwt.encode(claims, self.key, algorithm="RS256")

    def activity(self):
        return {
            "channelId": "msteams", "serviceUrl": "https://smba.trafficmanager.net/teams/",
            "channelData": {"tenant": {"id": "tenant"}},
            "conversation": {"conversationType": "personal"}, "from": {"aadObjectId": "a"},
        }


class IdentityBoundaryTests(SignedIdentityFixture, unittest.TestCase):
    def test_signed_api_token_cannot_choose_another_officer(self):
        self.assertEqual(self.auth.officer(self.auth.api(self.token())["oid"]).container, "a-container")
        with self.assertRaises(Denied):
            self.auth.officer("other")

    def test_bad_audience_scope_expiry_and_signature_are_denied(self):
        tokens = [self.token(aud="other"), self.token(scp=""), self.token(exp=1)]
        other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        tokens.append(jwt.encode(jwt.decode(self.token(), options={"verify_signature": False}),
                                 other_key, algorithm="RS256"))
        for token in tokens:
            with self.subTest(token=token[:10]), self.assertRaises(Denied):
                self.auth.api(token)

    def test_downstream_storage_token_must_match_caller(self):
        token = self.token(aud="https://storage.azure.com", scp="user_impersonation")
        self.assertEqual(self.auth.storage(token, "a")["oid"], "a")
        with self.assertRaises(Denied):
            self.auth.storage(token, "b")

    def test_officer_cannot_use_approval_authority(self):
        with self.assertRaises(Denied):
            self.auth.approver("a")

    def test_bot_service_url_tenant_and_personal_scope_are_bound(self):
        token = self.token(iss="https://api.botframework.com", aud="bot",
                           serviceurl="https://smba.trafficmanager.net/teams/")
        self.assertEqual(self.auth.bot(token, self.activity()), "a")
        for key, value in [
            ("serviceUrl", "https://attacker.example/"),
            ("channelData", {"tenant": {"id": "other"}}),
            ("conversation", {"conversationType": "groupChat"}),
            ("channelId", "webchat"),
            ("from", {"id": "untrusted", "aadObjectId": ""}),
        ]:
            activity = self.activity()
            activity[key] = value
            with self.subTest(key=key), self.assertRaises(Denied):
                self.auth.bot(token, activity)

    def test_bot_channel_endorsement_is_required(self):
        self.auth.bot_keys = SimpleNamespace(get_signing_key_from_jwt=lambda token: SimpleNamespace(
            key=self.key.public_key(), _jwk_data={"endorsements": []}))
        token = self.token(iss="https://api.botframework.com", aud="bot",
                           serviceurl="https://smba.trafficmanager.net/teams/")
        with self.assertRaises(Denied):
            self.auth.bot(token, self.activity())


class ApplicationBoundaryTests(SignedIdentityFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        import main
        self.main = main
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ledger = Ledger(str(Path(self.directory.name) / "ledger.sqlite3"))
        self.model = Mock()
        self.services_patch = patch("main.services", return_value=(self.auth, self.ledger, None, self.model))
        self.services_patch.start()
        self.addCleanup(self.services_patch.stop)
        self.client = TestClient(main.app)
        self.content = synthetic_pdf()
        self.officer = self.auth.officer("a")
        self.blobs = FakeBlobs(self.content)
        self.source_patch = patch("main.source", return_value=(self.officer, self.blobs))
        self.source_patch.start()
        self.addCleanup(self.source_patch.stop)
        self.environment = patch.dict(os.environ, {
            "PUBLIC_ORIGIN": "https://example.azurewebsites.net", "MODEL_DEPLOYMENT": "tax-chat",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def approved_document(self):
        row = self.ledger.submit(self.officer, "tax.pdf", self.content, "v1")
        self.ledger.approve(row["id"], row["sha256"], "approver", True)
        return row

    def test_api_rejects_spoofed_identity_and_extra_partition_fields(self):
        response = self.client.get("/v1/documents", headers={"x-ms-client-principal-id": "a"})
        self.assertEqual(response.status_code, 403)
        response = self.client.post("/v1/chat", headers={"Authorization": f"Bearer {self.token()}"},
                                    json={"question": "tax", "partition": "b"})
        self.assertEqual(response.status_code, 422)
        self.model.chat.completions.create.assert_not_called()

    def test_model_cannot_supply_a_citation_url(self):
        self.approved_document()
        self.model.chat.completions.create.return_value = SimpleNamespace(choices=[
            SimpleNamespace(message=SimpleNamespace(content='{"answer":"https://attacker.example",'
                                                          '"supported":true,"citations":[1]}'))])
        response = self.client.post("/v1/chat", json={"question": "tax payment"},
                                    headers={"Authorization": f"Bearer {self.token()}"})
        self.assertEqual(response.status_code, 422)

    def test_citation_url_is_server_owned_and_response_is_not_cached(self):
        row = self.approved_document()
        self.model.chat.completions.create.return_value = SimpleNamespace(choices=[
            SimpleNamespace(message=SimpleNamespace(content='{"answer":"The payment is 7319 dollars.",'
                                                          '"supported":true,"citations":[1]}'))])
        response = self.client.post("/v1/chat", json={"question": "tax payment"},
                                    headers={"Authorization": f"Bearer {self.token()}"})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(response.json()["citations"][0]["url"],
                         f"https://example.azurewebsites.net/documents/{row['id']}/content#page=1")

    def test_revocation_during_inference_prevents_answer_release(self):
        row = self.approved_document()
        def revoke(**kwargs):
            self.ledger.approve(row["id"], row["sha256"], "approver", False)
            return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(
                content='{"answer":"The payment is 7319 dollars.","supported":true,"citations":[1]}'))])
        self.model.chat.completions.create.side_effect = revoke
        response = self.client.post("/v1/chat", json={"question": "tax payment"},
                                    headers={"Authorization": f"Bearer {self.token()}"})
        self.assertEqual(response.status_code, 403)

    def test_officer_cannot_approve_through_http_endpoint(self):
        row = self.approved_document()
        response = self.client.post(f"/v1/approvals/{row['id']}", json={"sha256": row["sha256"]},
                                    headers={"Authorization": f"Bearer {self.token()}"})
        self.assertEqual(response.status_code, 403)

    def test_bot_endpoint_rejects_an_unsigned_activity(self):
        response = self.client.post("/api/messages", json=self.activity())
        self.assertEqual(response.status_code, 403)


if __name__ == "__main__":
    unittest.main()
