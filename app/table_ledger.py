import hashlib
import uuid

from azure.core import MatchConditions
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.data.tables import TableClient, UpdateMode

from core import Denied, LOG, Officer, StaleDocument, extract_pages, now


class TableLedger:
    """Approval metadata only; this identity has no officer PDF permissions."""

    def __init__(self, endpoint, credential):
        self.table = TableClient(endpoint, table_name="Approvals", credential=credential)

    @staticmethod
    def public(entity):
        return {key: value for key, value in entity.items() if key not in {"PartitionKey", "RowKey"}}

    def submit(self, officer: Officer, name: str, content: bytes, etag: str) -> dict:
        extract_pages(content)
        digest = hashlib.sha256(content).hexdigest()
        document_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"regiq:{officer.partition}:{name}"))
        entity = {
            "PartitionKey": officer.partition, "RowKey": document_id,
            "id": document_id, "partition": officer.partition, "owner": officer.oid,
            "name": name, "etag": etag, "sha256": digest, "status": "pending",
            "approver": "", "updated": now(),
        }
        try:
            current = self.table.get_entity(officer.partition, document_id)
        except ResourceNotFoundError:
            try:
                self.table.create_entity(entity)
            except ResourceExistsError as exc:
                raise StaleDocument("Concurrent submission; refresh and retry.") from exc
        else:
            if current["sha256"] == digest and current["etag"] == etag:
                return self.public(current)
            self.table.update_entity(
                entity, mode=UpdateMode.REPLACE, etag=current.metadata["etag"],
                match_condition=MatchConditions.IfNotModified,
            )
        LOG.info("submitted oid=%s document=%s hash=%s", officer.oid, document_id, digest)
        return self.public(entity)

    def list(self, partition: str | None = None) -> list[dict]:
        if partition is None:
            rows = self.table.list_entities(results_per_page=100)
        else:
            rows = self.table.query_entities(
                "PartitionKey eq @partition", parameters={"partition": partition},
                results_per_page=100,
            )
        return [self.public(row) for row in rows]

    def approve(self, document_id: str, digest: str, approver: str, approve: bool) -> dict:
        rows = list(self.table.query_entities("RowKey eq @id", parameters={"id": document_id}))
        if len(rows) != 1 or rows[0]["sha256"] != digest:
            raise StaleDocument("Unknown document or hash changed; refresh the approval queue.")
        row = rows[0]
        if row["owner"] == approver:
            raise Denied("Independent approval is required.")
        updated = dict(row)
        updated.update(status="approved" if approve else "rejected", approver=approver, updated=now())
        self.table.update_entity(
            updated, mode=UpdateMode.REPLACE, etag=row.metadata["etag"],
            match_condition=MatchConditions.IfNotModified,
        )
        LOG.info("approval oid=%s document=%s approved=%s", approver, document_id, approve)
        return {"id": document_id, "status": updated["status"]}

    def approved(self, officer: Officer, document_id: str) -> dict:
        try:
            row = self.table.get_entity(officer.partition, document_id)
        except ResourceNotFoundError as exc:
            raise Denied("No approved document is available to this officer.") from exc
        if row["status"] != "approved":
            raise Denied("No approved document is available to this officer.")
        return self.public(row)
