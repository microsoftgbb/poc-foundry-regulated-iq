import copy
import hashlib
import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import native_iq
import native_iq_evidence as evidence


class EvidenceBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.officer = next(iter(native_iq.BINDINGS))
        self.source = evidence.source_reference(
            self.officer, "case one/receipt #1.pdf", "2026-11-16T12:00:00.0000000Z",
            hashlib.sha256(b"synthetic-pdf-bytes").hexdigest(),
        )
        self.analyzer_hash = "a" * 64
        self.analyzer_id = f"case_evidence_{self.analyzer_hash[:16]}"
        result = {
            "status": "Succeeded",
            "result": {
                "analyzerId": self.analyzer_id,
                "contents": [{
                    "kind": "document", "markdown": "Invoice total: 18,450.",
                    "pages": [{"pageNumber": 1}],
                    "fields": {"StatedTotal": {"type": "number", "valueNumber": 18450}},
                }],
            },
        }
        self.envelope = evidence.analysis_envelope(
            self.source, self.analyzer_id, self.analyzer_hash, result
        )
        self.approval = {
            "status": "approved",
            "approver_oid": evidence.APPROVER_OBJECT_ID,
            "approval_id": "approval-001",
            "source": copy.deepcopy(self.source),
            "analyzer_sha256": self.analyzer_hash,
            "analysis_sha256": native_iq.canonical_hash(self.envelope),
        }

    def records(self, envelope=None, approval=None, current=None):
        return evidence.approved_records(
            envelope or self.envelope, approval or self.approval,
            current or self.source,
        )

    def test_exact_approval_preserves_fields_pages_and_versioned_citation(self):
        records = self.records()
        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertIn("receipt%20%231.pdf?versionid=", record["source_uri"])
        self.assertIn("StatedTotal", record["content"])
        self.assertEqual((record["page_start"], record["page_end"]), (1, 1))
        self.assertEqual(record["source_sha256"], self.source["sha256"])
        self.assertEqual(record["analysis_sha256"], native_iq.canonical_hash(self.envelope))
        self.assertEqual(records, self.records())

    def test_pending_withdrawn_self_and_cross_officer_approvals_fail(self):
        for field, value in (
            ("status", "pending"), ("status", "withdrawn"),
            ("approver_oid", self.officer),
            ("approver_oid", list(native_iq.BINDINGS)[1]),
            ("source", {**self.source, "container": "officer-b-pending"}),
            ("analyzer_sha256", "b" * 64),
            ("analysis_sha256", "b" * 64),
        ):
            approval = {**self.approval, field: value}
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.records(approval=approval)

    def test_source_update_withdrawal_or_replacement_fails(self):
        for field, value in (("version", "new-version"), ("sha256", "b" * 64),
                             ("container", "officer-b-pending")):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "Source changed"):
                self.records(current={**self.source, field: value})

    def test_tampering_with_analysis_after_approval_fails(self):
        envelope = copy.deepcopy(self.envelope)
        envelope["analysis"]["result"]["contents"][0]["markdown"] = "Forged evidence"
        with self.assertRaisesRegex(ValueError, "Independent approval"):
            self.records(envelope=envelope)

    def test_failure_foreign_analyzer_or_ungrounded_result_cannot_be_indexed(self):
        for mutate in ("failure", "analyzer", "pages", "empty"):
            envelope = copy.deepcopy(self.envelope)
            if mutate == "failure":
                envelope["analysis"]["status"] = "Failed"
            elif mutate == "analyzer":
                envelope["analysis"]["result"]["analyzerId"] = "prebuilt-document"
            elif mutate == "pages":
                envelope["analysis"]["result"]["contents"][0]["pages"] = []
            else:
                envelope["analysis"]["result"]["contents"] = []
            approval = {**self.approval, "analysis_sha256": native_iq.canonical_hash(envelope)}
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                self.records(envelope=envelope, approval=approval)

    def test_ownership_and_non_pdf_input_are_rejected(self):
        for name in ("", "receipt.exe", "bad\nname.pdf",
                     "../officer-b-pending/case.pdf", "case/../receipt.pdf",
                     "./receipt.pdf"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                evidence.source_reference(self.officer, name, "version", "a" * 64)
        source = {**self.source, "container": "officer-b-pending"}
        with self.assertRaisesRegex(ValueError, "ownership"):
            evidence.analysis_envelope(source, self.analyzer_id, self.analyzer_hash,
                                       self.envelope["analysis"])


if __name__ == "__main__":
    unittest.main()
