"""Exact-version approval contract for the native IQ ingestion boundary.

The caller must read approval records from the protected approval ledger, not
from an officer's upload or Content Understanding output. This module performs
integrity checks; it does not authenticate the approver or grant write access.
"""

import json
import re
from pathlib import PurePosixPath
from urllib.parse import quote, urlencode

from native_iq import BINDINGS, SOURCE_STORAGE, canonical_hash


APPROVER_OBJECT_ID = "c9b1eccf-3617-467e-9a8a-2f2228777d47"


def source_reference(officer_oid, blob_name, version, sha256):
    if officer_oid not in BINDINGS:
        raise ValueError("Unknown officer.")
    if (
        not isinstance(blob_name, str) or not blob_name or len(blob_name) > 1024
        or not blob_name.lower().endswith(".pdf")
        or any(part in (".", "..") for part in blob_name.split("/"))
        or any(ord(char) < 32 for char in blob_name)
        or not isinstance(version, str) or not version or len(version) > 128
    ):
        raise ValueError("A PDF Blob name and exact version ID are required.")
    if not isinstance(sha256, str) or not re.fullmatch(r"[a-f0-9]{64}", sha256):
        raise ValueError("A SHA-256 hash of the source bytes is required.")
    return {
        "officer_oid": officer_oid,
        "storage": SOURCE_STORAGE,
        "container": BINDINGS[officer_oid],
        "blob": blob_name,
        "version": version,
        "sha256": sha256,
    }


def analysis_envelope(source, analyzer_id, analyzer_hash, result):
    source_reference(source["officer_oid"], source["blob"], source["version"],
                     source["sha256"])
    if source["container"] != BINDINGS[source["officer_oid"]] or source["storage"] != SOURCE_STORAGE:
        raise ValueError("Source ownership does not match the officer.")
    if not re.fullmatch(r"case_evidence_[a-f0-9]{16}", analyzer_id):
        raise ValueError("Expected the content-addressed custom analyzer ID.")
    if not re.fullmatch(r"[a-f0-9]{64}", analyzer_hash):
        raise ValueError("Missing analyzer definition hash.")
    if analyzer_id != f"case_evidence_{analyzer_hash[:16]}":
        raise ValueError("Analyzer ID does not match its definition hash.")
    if result.get("status", "").lower() != "succeeded":
        raise ValueError("Content Understanding analysis did not succeed.")
    if result.get("result", {}).get("analyzerId") != analyzer_id:
        raise ValueError("Analysis was not produced by the selected custom analyzer.")
    return {
        "source": source,
        "analyzer_id": analyzer_id,
        "analyzer_sha256": analyzer_hash,
        "analysis": result,
    }


def approved_records(envelope, approval, current_source):
    """Convert a trusted approval and matching current source into index records."""
    source = envelope["source"]
    analysis_envelope(source, envelope["analyzer_id"], envelope["analyzer_sha256"],
                      envelope["analysis"])
    if current_source != source:
        raise ValueError("Source changed, was withdrawn, or is no longer available.")
    if (
        approval.get("status") != "approved"
        or approval.get("approver_oid") != APPROVER_OBJECT_ID
        or approval.get("approver_oid") == source["officer_oid"]
        or approval.get("source") != source
        or approval.get("analyzer_sha256") != envelope["analyzer_sha256"]
        or approval.get("analysis_sha256") != canonical_hash(envelope)
    ):
        raise ValueError("Independent approval does not bind this exact analysis and source.")
    approval_id = approval.get("approval_id")
    if not isinstance(approval_id, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,128}", approval_id):
        raise ValueError("Invalid approval record ID.")
    source_url = (
        f"https://{SOURCE_STORAGE}.blob.core.windows.net/{source['container']}/"
        f"{quote(source['blob'], safe='/')}?{urlencode({'versionid': source['version']})}"
    )
    contents = envelope["analysis"]["result"].get("contents")
    if not isinstance(contents, list) or not contents:
        raise ValueError("Successful analysis contained no document evidence.")
    records = []
    for content in contents:
        if content.get("kind") != "document":
            raise ValueError("Only document analysis can enter the PDF evidence index.")
        text = content.get("markdown")
        pages = content.get("pages")
        if not isinstance(text, str) or not text.strip() or not isinstance(pages, list) or not pages:
            raise ValueError("Evidence must contain text and page grounding.")
        numbers = [page.get("pageNumber") for page in pages]
        if any(type(number) is not int or number < 1 for number in numbers):
            raise ValueError("Invalid page grounding.")
        extracted = content.get("fields")
        if extracted:
            text += "\n\nCustom analyzer fields (check against cited original):\n"
            text += json.dumps(extracted, ensure_ascii=True, sort_keys=True)
        for offset in range(0, len(text), 12000):
            key = canonical_hash({
                "source": source, "approval_id": approval_id, "part": len(records),
            })
            records.append({
                "id": key,
                "title": PurePosixPath(source["blob"]).name,
                "content": text[offset:offset + 12000],
                "officer_oid": source["officer_oid"],
                "source_uri": source_url,
                "source_version": source["version"],
                "source_sha256": source["sha256"],
                "analyzer_version": envelope["analyzer_sha256"],
                "analysis_sha256": canonical_hash(envelope),
                "approval_id": approval_id,
                "page_start": min(numbers),
                "page_end": max(numbers),
                "approved": True,
            })
    return records
