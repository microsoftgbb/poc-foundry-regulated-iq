import hashlib
import json
import logging
import re
import sqlite3
import subprocess
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol

from azure.core import MatchConditions
from azure.core.credentials import AccessToken
from azure.storage.blob import BlobServiceClient

MAX_PDF_BYTES = 20 * 1024**2
LOG = logging.getLogger("regiq.audit")


class Denied(Exception):
    pass


class InvalidDocument(Exception):
    pass


class StaleDocument(Exception):
    pass


@dataclass(frozen=True)
class Officer:
    oid: str
    partition: str
    container: str


class ApprovalReader(Protocol):
    def list(self, partition: str | None = None) -> list[dict]: ...
    def approved(self, officer: Officer, document_id: str) -> dict: ...


class DelegatedCredential:
    def __init__(self, token: str, expires: int):
        self.token = AccessToken(token, expires)

    def get_token(self, *scopes, **kwargs):
        return self.token


class BlobDocuments:
    def __init__(self, endpoint: str, token: str, expires: int, officer: Officer):
        self.container = BlobServiceClient(
            endpoint, credential=DelegatedCredential(token, expires),
            logging_enable=False,
        ).get_container_client(officer.container)

    def list(self) -> list[dict]:
        documents = []
        for blob in self.container.list_blobs(results_per_page=100):
            if len(documents) == 100:
                raise InvalidDocument("This PoC supports at most 100 blobs per container.")
            if blob.name.lower().endswith(".pdf"):
                documents.append({"name": blob.name, "size": blob.size})
        return documents

    def read(self, name: str, expected_etag: str | None = None) -> tuple[bytes, str]:
        if not name or len(name) > 1024 or not name.lower().endswith(".pdf"):
            raise InvalidDocument("Specify a PDF blob name, not a URL or container.")
        client = self.container.get_blob_client(name)
        properties = client.get_blob_properties()
        if properties.size > MAX_PDF_BYTES:
            raise InvalidDocument("PDF exceeds the 20 MiB limit.")
        if expected_etag and properties.etag != expected_etag:
            raise StaleDocument("The source changed; submit the new version for approval.")
        content = client.download_blob(
            etag=properties.etag, match_condition=MatchConditions.IfNotModified,
            max_concurrency=1,
        ).readall()
        if len(content) > MAX_PDF_BYTES:
            raise InvalidDocument("PDF exceeds the 20 MiB limit.")
        return content, properties.etag


def extract_pages(content: bytes) -> list[str]:
    if len(content) > MAX_PDF_BYTES:
        raise InvalidDocument("PDF exceeds the 20 MiB limit.")
    if sys.platform != "linux":
        LOG.warning("parser_memory_limit_unavailable platform=%s; production requires Linux", sys.platform)
    try:
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("pdf_extract.py"))],
            input=content, capture_output=True, timeout=15, check=False,
            env={"PATH": "/usr/bin:/bin", "PYTHONIOENCODING": "utf-8"},
        )
    except subprocess.TimeoutExpired as exc:
        raise InvalidDocument("PDF extraction exceeded the time limit.") from exc
    if result.returncode != 0:
        LOG.warning("pdf_extraction_rejected exit=%s", result.returncode)
        raise InvalidDocument("PDF validation failed; use a valid synthetic, text-based PDF.")
    parsed = json.loads(result.stdout)
    return parsed["pages"]


class Ledger:
    def __init__(self, path: str):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        with self.connect() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY, partition TEXT NOT NULL, owner TEXT NOT NULL,
                name TEXT NOT NULL, etag TEXT NOT NULL, sha256 TEXT NOT NULL,
                status TEXT NOT NULL, approver TEXT, updated TEXT NOT NULL,
                UNIQUE(partition, name))""")

    def connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        return db

    def submit(self, officer: Officer, name: str, content: bytes, etag: str) -> dict:
        extract_pages(content)
        digest = hashlib.sha256(content).hexdigest()
        with self.connect() as db:
            db.execute("""INSERT INTO documents VALUES (?, ?, ?, ?, ?, ?, 'pending', NULL, ?)
                ON CONFLICT(partition, name) DO UPDATE SET owner=excluded.owner,
                etag=excluded.etag, sha256=excluded.sha256, status='pending',
                approver=NULL, updated=excluded.updated
                WHERE documents.etag != excluded.etag OR documents.sha256 != excluded.sha256""",
                (str(uuid.uuid4()), officer.partition, officer.oid, name, etag, digest, now()))
            row = db.execute(
                "SELECT * FROM documents WHERE partition=? AND name=?",
                (officer.partition, name),
            ).fetchone()
        LOG.info("submitted oid=%s document=%s hash=%s", officer.oid, row["id"], digest)
        return dict(row)

    def list(self, partition: str | None = None) -> list[dict]:
        with self.connect() as db:
            if partition is None:
                rows = db.execute("SELECT * FROM documents ORDER BY updated DESC").fetchall()
            else:
                rows = db.execute("SELECT * FROM documents WHERE partition=?", (partition,)).fetchall()
        return [dict(row) for row in rows]

    def approve(self, document_id: str, digest: str, approver: str, approve: bool) -> dict:
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM documents WHERE id=?", (document_id,)).fetchone()
            if row is None or row["sha256"] != digest:
                raise StaleDocument("Unknown document or hash changed; refresh the approval queue.")
            if row["owner"] == approver:
                raise Denied("Independent approval is required.")
            db.execute("UPDATE documents SET status=?, approver=?, updated=? WHERE id=?",
                       ("approved" if approve else "rejected", approver, now(), document_id))
        LOG.info("approval oid=%s document=%s approved=%s", approver, document_id, approve)
        return {"id": document_id, "status": "approved" if approve else "rejected"}

    def approved(self, officer: Officer, document_id: str) -> dict:
        with self.connect() as db:
            row = db.execute(
                "SELECT * FROM documents WHERE id=? AND partition=? AND status='approved'",
                (document_id, officer.partition),
            ).fetchone()
        if row is None:
            raise Denied("No approved document is available to this officer.")
        return dict(row)


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def verified_source(row: dict, blobs: BlobDocuments) -> bytes:
    content, _ = blobs.read(row["name"], row["etag"])
    if hashlib.sha256(content).hexdigest() != row["sha256"]:
        raise StaleDocument("The source no longer matches its approval.")
    return content


def retrieve(ledger: ApprovalReader, officer: Officer, blobs: BlobDocuments, question: str) -> list[dict]:
    terms = set(re.findall(r"[a-z0-9]{2,}", question.lower()))
    candidates = []
    approved = [row for row in ledger.list(officer.partition) if row["status"] == "approved"]
    if len(approved) > 20:
        raise InvalidDocument("This PoC supports at most 20 approved PDFs per officer.")
    for row in approved:
        content = verified_source(ledger.approved(officer, row["id"]), blobs)
        for page_number, text in enumerate(extract_pages(content), 1):
            for offset in range(0, len(text), 1400):
                passage = text[offset:offset + 1600]
                score = sum(passage.lower().count(term) for term in terms)
                if score:
                    candidates.append({
                        "document": row["id"], "name": row["name"], "page": page_number,
                        "text": passage, "score": score, "sha256": row["sha256"],
                        "etag": row["etag"],
                    })
    return sorted(candidates, key=lambda passage: passage["score"], reverse=True)[:6]
