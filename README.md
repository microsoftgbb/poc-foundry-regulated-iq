# Foundry regulated IQ: private Foundry agents in Teams PoC

## Purpose

Officers ask questions in Microsoft Teams about **their own approved case documents** and get answers that cite the document and page. The agents are native Microsoft Foundry prompt agents with a Foundry IQ (Azure AI Search) knowledge base. Officers upload PDFs in the Azure Portal, and an approver releases each document before it can be searched.

Foundry, AI Search, Content Understanding, Cosmos DB and the evidence stores have public network access disabled and use Microsoft Entra ID or managed identities only. Teams reaches the agents through Foundry's Microsoft 365 Activity route (`enable_m365_public_endpoint` with `BotServiceRbac`).

Two ways of keeping officers apart are deployed:

| | Per-officer agents | Shared agent |
|---|---|---|
| Isolation | Separate Foundry account, Search service, knowledge base and agent per officer | One index; each record carries a Search access control list (`userIds`), and the agent searches with the signed-in officer's token |
| Teams app | One per officer | One for all officers |
| Add an officer | Deploy another domain | Add an entry to `config/officers.json` and sync the officer group |

| Part | What it is |
|------|------------|
| [docs/getting-started.md](docs/getting-started.md) | Deploy, configure, operate and add officers. |
| [docs/architecture.md](docs/architecture.md) | Components, network paths, identities, approval gate and audit. |
| [docs/fallback-custom-engine-agent.md](docs/fallback-custom-engine-agent.md) | Design (not built) for a custom front end over the shared index. |
| [docs/diagrams/](docs/diagrams/) | Architecture and sequence diagrams (PNG, SVG, Mermaid). |
| `infra/bicep/` | Stage templates and `modules/`. |
| `config/` | Officer registry, Content Understanding analyzer, agent instructions. |
| `scripts/` | Configuration, ingestion, publishing and group sync, run inside the VNet by Azure Container Instances jobs. |
| `test/` | Unit tests for the per-officer service definitions. |

## Architecture

Shared agent:

![Shared agent architecture](docs/diagrams/case-iq-shared-agent-architecture.png)

Per-officer agents:

![Per-officer architecture](docs/diagrams/case-iq-per-officer-architecture.png)


## Data flows

### Upload and approval

1. The officer uploads a PDF in the Azure Portal to their own container `officer-<key>-pending`.
2. Every 5 minutes, a Logic App starts the ingestion job. It sends the current Blob version to the Content Understanding custom analyzer and stores the result. Analysis alone makes nothing searchable.
3. The approver sets the Blob index tag `approval=approved`. Officers can't read or write tags.
4. On the next run, the job writes per-page and extracted-field records with the source version, SHA-256, analyzer version and approval ID:
   - **Per-officer agents:** to the officer's own evidence store, indexed by a private indexer.
   - **Shared agent:** pushed to the shared index with `userIds = [officer object ID]` and a Portal link to the source PDF. The object ID comes from the container binding in `config/officers.json`.
5. Deleting the PDF, uploading a new version or removing the tag withdraws the records on the next run.

### Chat

1. The officer asks the agent a question in Teams.
2. The agent calls `knowledge_base_retrieve`, the only tool it has, and answers only from the returned evidence, citing the document and page.
   - **Per-officer agents:** the agent retrieves with its project's managed identity from the officer's own index.
   - **Shared agent:** the `UserEntraToken` connection sends the officer's token in `x-ms-query-source-authorization`. Search returns only records whose `userIds` match the signed-in officer.

## Security model

- **Private networking.** Foundry, Search, Content Understanding, Cosmos DB and the evidence and runtime stores have `publicNetworkAccess` disabled and private endpoints. On Foundry, only the Microsoft 365 Activity route is reachable from outside. The upload storage account accepts Portal traffic with Entra authorization only.
- **No keys.** Shared keys and local authentication are disabled. Services use managed identities and Entra tokens.
- **Least privilege.** Each identity holds only the roles it needs:
  - Officers: their own upload container, plus chat with the agent.
  - The approver: read PDFs and set the approval tag (custom role).
  - The ingestion job: read PDFs and tags, analyze, write evidence and records.
  - The scheduler: start the job only.
  - See [docs/architecture.md](docs/architecture.md#identities-and-roles).
- **Approval before exposure.** Only approved, exact Blob versions are indexed. Knowledge sources filter `approved eq true`.
- **Document-level security (shared agent).** Search ACLs are evaluated against the caller's token. Without a user token, the index returns no records.
- **Agent tools.** Each agent has only `knowledge_base_retrieve`, with `require_approval: never`. Its instructions treat document text as evidence, not instructions.
- **Audit.** Diagnostic settings send Storage, Foundry and scheduler operations to Log Analytics, with no document, prompt or answer text. Search operation logs can include query text. The shared domain isn't covered by the audit template yet.

## License

[MIT](LICENSE)
