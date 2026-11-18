# Architecture

## Components

| Component | Per-officer agents | Shared agent | Template |
|---|---|---|---|
| Upload storage and VNet | Shared: storage account with one container per officer, VNet `10.82.0.0/16`, Blob private endpoint | Same | `foundation.bicep`, `modules/private-uploads.bicep` |
| Foundry account and project | `regiq-{a,b}-…` / `caseiq`, one per officer | `regiq-s-…` / `caseiq` | `per-officer-domains.bicep`, `shared-agent.bicep` |
| Agent subnet (network injection) | `native-agent-{a,b}` | `native-agent-s` | same |
| Models | `case-chat` (gpt-5.1) and `case-embedding` (text-embedding-3-small), regional Standard | Same | same |
| Content Understanding analyzer | One per officer | One shared | `config/content-understanding/case-evidence-analyzer.json` |
| Evidence store | `riq{a,b}…`: `analysis-pending`, `approved-content`, `approval-ledger` | `riqs…`: `analysis-pending`, `approved-content` (pushed record IDs), `approval-ledger` | same |
| AI Search | S1 per officer, private indexer from `approved-content` | Basic, local authentication disabled, index `case-evidence-shared` with `permissionFilterOption=enabled` and a `userIds` field | same |
| Foundry IQ knowledge base | `case-evidence`, filter `approved eq true and officer_oid eq '<officer>'` | `case-evidence-shared`, filter `approved eq true` | configure scripts |
| Agent connection | `ProjectManagedIdentity` | `UserEntraToken` | configure scripts |
| Agent runtime stores | Per-officer Cosmos DB, runtime Blob, Search (capability host) | Shared | same |
| Ingestion | Logic App (every 5 minutes) starts an ACI job with its own managed identity | Same job, shared pipeline | `ingestion.bicep`, `scripts/ingest.ps1` |
| Configuration | ACI job in subnet `native-config` with an outbound-only NAT gateway | Same job, `script=shared` | `config-network.bicep`, `config-job.bicep` |
| Audit | Diagnostic settings to Log Analytics `regiq-audit-logs` | Same | `audit.bicep` |

Search runs in East US, and the other services in East US 2.

## Network paths

- **Officer to upload storage:** Azure Portal over the public endpoint, with Entra authorization only. Shared keys and anonymous access are disabled.
- **Teams to agent:** Foundry's Microsoft 365 Activity route. It is source-IP filtered by Foundry, and the agent endpoint requires `BotServiceRbac`. Every other Foundry endpoint is reachable only through its private endpoint.
- **Agent to knowledge base:** from the Foundry agent subnet to the Search private endpoint.
- **Jobs to services:** the ACI jobs run in `native-config` and reach Storage, Content Understanding, Search and Foundry through private endpoints. Each script refuses an endpoint that doesn't resolve to a private address.
- **Private DNS:** `privatelink` zones for blob, file, cognitiveservices, openai, services.ai, search and documents are linked to the VNet.

## Identities and roles

| Principal | Roles and scope | Can't |
|---|---|---|
| Officer | Storage Blob Data Contributor on their own container. Per-officer agents: Foundry Agent Consumer on their project. Shared agent, through the group **Case IQ Officers**: Foundry Agent Consumer on the shared project, Search Index Data Reader on the shared Search service, Reader on the upload account | Read other containers, set approval tags, retrieve other officers' records |
| Approver | **RegIQ Case Approver** (custom) on the upload account: read blobs, read and write tags | Upload, change or delete PDFs |
| Ingestion identity | **RegIQ Case Ingestion Reader** (custom) on each officer container; Content Understanding Reader; Blob Data Contributor on evidence stores; Search Service Contributor (per officer) and Search Index Data Contributor (shared) | Set approval tags, change source PDFs, manage agents |
| Scheduler (Logic App) | **RegIQ Ingestion Starter** (custom): read and start the ingestion job | Change the job or its identity |
| Configuration identity | Content Understanding Contributor, Search Service Contributor, Foundry User and Contributor on the project; Search Index Data Contributor on the shared Search service, used by the isolation tests | Read source PDFs or the approval ledger |
| Project identity | Search Index Data Reader; capability-host stores | Retrieve shared-index records (no user token) |

Officer membership comes from `config/officers.json`:
- `scripts/sync-officer-group.ps1` keeps the group in step with the file.
- `infra/bicep/officers.bicep` creates each container and its upload role.

## Approval gate

![Document lifecycle](diagrams/case-iq-document-lifecycle-sequence.png)


- Approval is the Blob index tag `approval=approved` on the exact current version. Only the approver role can write tags.
- The ingestion job checks that the stored analysis matches the source container, Blob version and analyzer version before it publishes. It records each approval in `approval-ledger`.
- Withdrawal (tag removed or changed, PDF deleted, or new version uploaded):
  - **Per-officer:** rewrites the records as `approved=false` tombstones and re-indexes.
  - **Shared:** deletes the pushed record IDs from the index.
- Changes take effect on the next run (about 5 minutes, plus indexing). Answers already sent in Teams aren't retracted.

## Document-level security (shared agent)

- Each record has `userIds = [officer object ID]`. The ID comes from the officer-to-container binding in the registry, never from document content.
- The index has `permissionFilterOption=enabled`. Search builds the permission filter from the token in `x-ms-query-source-authorization`.
- The agent's `UserEntraToken` connection supplies the signed-in user's token. A request without a user token returns no records, and a service principal calling the agent is refused.
- Search has local authentication disabled, so no API key can bypass the filter.

## Citations

- **Per-officer agents:** cite the document name and page in the answer text.
- **Shared agent:** each record carries `portal_url`, an Azure Portal link to the source blob. It is built only from the fixed account, the officer's container and the blob name. The agent lists these links under "Sources", and the officer opens the PDF with their own access.

## Audit logging

`audit.bicep` sends diagnostics to Log Analytics `regiq-audit-logs` for:
- **Upload and per-officer evidence storage:** `StorageRead`, `StorageWrite` and `StorageDelete`, with the caller identity, not blob content.
- **Per-officer Search services:** `OperationLogs`. These can include query text.
- **Per-officer Foundry accounts:** `Audit`.
- **Scheduler:** `WorkflowRuntime`.

The shared domain (`regiq-s-…`, `riqs…`) isn't covered by `audit.bicep` yet.

## Known limits

- The shared agent's knowledge base connection uses preview APIs. The MCP endpoint runs on `2026-08-01-preview`.
- Teams doesn't render Foundry citation cards, so references appear in the answer text.
- Permissions are only as fresh as the last ingestion run.
