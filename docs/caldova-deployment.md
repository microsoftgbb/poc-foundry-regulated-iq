# Caldova deployment results

Checked: 2026-11-17 UTC.

**The diagram is implemented end to end in both officer domains and verified
live: Portal upload -> own Blob -> Content Understanding custom analyzer ->
approval -> private indexing -> Foundry IQ -> native agent -> Teams.**
Teams chat itself needs each officer to sign in; see the runbook below.

Option B (one shared agent, per-officer document ACLs) runs alongside this
pilot in `regiq-s-3a2hsmj55wycu`; see [option-b-shared-agent.md](option-b-shared-agent.md).
The ingestion job now also mirrors approved records into its shared index.

## As-built pipeline (2026-11-17)

| Stage | Implementation | Low-code surface |
| --- | --- | --- |
| Upload | Officer uploads a PDF to their own container in Azure Portal (`officer-a-pending` / `officer-b-pending`) | Azure Portal |
| Schedule | Consumption Logic App `regiq-ingest-yvgv5nwqzm5aa-schedule` checks every 5 minutes and starts the job only when it is idle | Logic Apps designer |
| Analyze | Private ACI job `regiq-ingest-yvgv5nwqzm5aa-job` sends the exact Blob version to the officer's own CU custom analyzer, with `processingLocation=geography`; the result is stored in that officer's `analysis-pending` | none (reconciler) |
| Approve | The approver sets Blob index tag `approval=approved` on the PDF in Azure Portal | Azure Portal |
| Publish | Approved analysis becomes per-page and extracted-field records in `approved-content`; an `approval-ledger` entry is written and the private indexer runs | none (reconciler) |
| Retrieve | Foundry IQ knowledge base over the officer's own index, filtered to `approved eq true` and that officer | Foundry |
| Chat | Native prompt agent `caseiq`, published to Teams with `Shared` scope and `BotServiceRbac` | Teams |
| Withdraw | Removing/changing the tag, deleting the PDF or uploading a new version rewrites the records as `approved=false` tombstones and re-indexes | Azure Portal |
| Audit | Storage read/write/delete, Search operations, Foundry `Audit` and scheduler runtime go to `regiq-audit-logs`; no prompts, answers or document text | Azure Monitor |

Authorization boundaries, verified through live role inspection:

| Principal | Can | Cannot |
| --- | --- | --- |
| Officer A / B | Upload, read and delete in **own** pending container; chat with **own** agent (`Foundry Agent Consumer` on own project only) | Approve (no tag write), see the other container, call the other agent |
| Approver (operator) | Read PDFs and set/remove the approval tag (`RegIQ Case Approver`) | Upload or change PDFs |
| Ingestion identity | Read PDFs and tags (`RegIQ Case Ingestion Reader`), analyze with CU (`Content Understanding Reader`), write own evidence stores, run indexers | Approve, change source PDFs, manage agents |
| Scheduler | Read and start the ingestion job (`RegIQ Ingestion Starter`) | Change the job definition or identity |

Both Foundry accounts keep public network access **Disabled**. The only
public path is Foundry's source-IP-filtered, token-authorized Activity route
used by Teams. Evidence, runtime and Search services stay private; the
source upload account keeps its approved Portal exception with shared keys
and anonymous access disabled.

### Live end-to-end proof

Synthetic PDFs were uploaded to each officer container (operator test-upload
role granted temporarily and then removed), analyzed, approved by tag,
published and indexed. Private checks through each native agent
(`infra/native-config-job.bicep` with `e2eCases`) then passed:

| Check | Result |
| --- | --- |
| Officer A asks for invoice INV-A-7731 total | "CAD 6,037.50 ... page 2 of case-a-invoice.pdf" |
| Officer A asks about officer B's return | "I don't know from the approved case evidence." |
| Officer B asks for return RET-B-4402 net tax | "3,290.00 CAD ... page 2 of case-b-return.pdf" |
| Officer B asks about officer A's invoice | "I don't know from the approved case evidence." |
| Approval removed from A's PDF, reconcile, ask again | "I don't know from the approved case evidence." |
| Approval restored, reconcile, all four checks | PASS |

Both agents were then published to Teams through the private one-shot job
`infra/native-publish-job.bicep` using the operator's short-lived token as a
secure value; the job was deleted afterwards.

| Officer | Teams app | Title ID |
| --- | --- | --- |
| AadiK (A) | `350ea139-79ad-4e22-ab78-c52e502db28c` | `T_83d7ab87-af5f-4a21-ca28-cd376a74b225` |
| AndreL (B) | `57922f0d-dc95-43e8-8c36-2572f551b06f` | `T_359213a4-3069-388b-3c95-44094e144880` |

### Runbook

1. **Officer uploads** a PDF in Azure Portal: storage account
   `regiqvqx35xnseaqaw` > Containers > own `officer-*-pending` > Upload.
   Analysis runs within 5 minutes.
2. **Approver approves** in Azure Portal: open the PDF > **Blob index tags** >
   add `approval` = `approved` > Save. Indexing follows within 5 minutes.
   To withdraw, delete the tag or set another value.
3. **Officer chats** in Teams: open
   `https://teams.microsoft.com/l/app/<Teams app ID>` for their own agent,
   select **Add**, and ask questions. Answers name the PDF and page. Teams
   doesn't render Foundry citation cards, so references are in the text.
4. To process immediately, open the scheduler Logic App and select
   **Run trigger**.
5. To republish after changing the agent, rerun the publish job with a new
   `appVersion`, then delete the `regiq-publish-teams-job` container group.

Shared scope lists each agent under **Your agents** only for the publisher;
officers add it through the link. BotServiceRbac still rejects any user
without `Foundry Agent Consumer` on that officer's project.

## Native implementation - current state

`regiq-native-dependencies-recovery-20261116` succeeded. The two S1 Search
services are in **East US** because both East US 2 creates failed for physical
capacity. Cosmos, Storage and the VNet remain in East US 2.

| Component | Observed state |
| --- | --- |
| Search | `regiq-a-3a2hsmj55wycu` and `regiq-b-3a2hsmj55wycu`: succeeded, Entra-only, public access disabled |
| Evidence Storage | `riqa3a2hsmj55wycu` and `riqb3a2hsmj55wycu`; separate pending-analysis, approved-content and approval-ledger containers |
| Runtime file Storage | Separate `riha3a2hsmj55wycu` and `rihb3a2hsmj55wycu`, so required Foundry storage administration cannot alter evidence or approvals |
| Cosmos | Separate per-officer serverless accounts, private endpoints |
| Private ingress | All ten native endpoints plus the original upload endpoint Succeeded and Approved; Search DNS has configured `10.82.1.12` / `10.82.1.11` records in the linked private zone |
| Private indexing | Both Search-to-own-Blob shared private links explicitly approved |
| Indexer data roles | Each Search identity has Blob Data Reader only on its own `approved-content` container |
| Foundry runtime | Both private accounts, `caseiq` projects and project capability hosts Succeeded; each host explicitly references its own three AAD/managed-identity connections |
| Models | Both accounts have regional Standard `case-chat` and `case-embedding` deployments; no GlobalStandard substitution |
| Actual platform stores | Each own Cosmos has `enterprise_memory`, classic containers, `agent-definitions-v1` and `run-state-v1`; each own runtime Blob has its platform containers |
| CU analyzer / IQ definitions | Applied in both domains; configuration job completed with exit 0 |
| Native prompt agents | `caseiq` exists in each private project; each own Cosmos now has project-prefixed `agent-definitions-v1` |
| Private administrative execution | Digest-pinned Microsoft PowerShell ACI job, existing scoped MI, private IP, no volumes or exposed ports |
| Native IQ runtime smoke | Each agent completed a synthetic response with one successful own-IQ retrieval call; job exit 0 |
| Extraction/approval/withdrawal workflow | Deployed and verified live (see above) |
| Officer access / Teams publishing | Own-project `Foundry Agent Consumer`; both agents published to Teams |

Account-default runtime requests failed with contradictory
`LinkedInvalidPropertyId` errors: the full Search ARM ID was rejected in
favor of a resource name, then that name was rejected in favor of a full ID.
The published September API reproduced the full-ID error. Project-create
settings were then accepted but did not produce connections or customer-owned
stores, so that success was not treated as BYO proof.

The documented explicit capability-host path succeeded in
`regiq-native-runtime-host-corrected-20261116`, correlation
`76b14c92-c115-4f70-81e8-b1bc211eecb2`. It reuses both healthy account hosts
and binds each project host to its own runtime Blob, Cosmos and Search.
The first connection attempt exposed a documentation mismatch: the actual
Cosmos category enum is `CosmosDb`, not the conceptual article's
`AzureCosmosDb`. All three connections explicitly select workspace managed
identity. A read-only live check verified both Succeeded hosts and each
connection's authentication, MI flag, category, endpoint and ResourceId.
Customer-owned platform containers now exist, unlike the ineffective
project-settings attempt.

Each revision passed fresh formal ARM validation/what-if first. The final
preview had four resource creates and **zero resource deletions**. No account,
project or capability host was deleted or purged, and neither healthy agent
subnet was changed. Project Search authority remains Data Reader only.
This proves infrastructure binding and classic platform-store provisioning,
**not** an end-to-end officer authorization proof. Subsequently, native agent
creation produced `agent-definitions-v1` in each correct Cosmos account.
Subsequent native response tests also produced `run-state-v1` in each correct
Cosmos account and completed each own-IQ retrieval path. This does not prove
case ingestion, evidence-bearing answers or officer authorization.

The current Azure retail S1 rate for East US was verified as USD 0.336 per
unit-hour: **USD 490.56/month for two single-unit Search services**, using
730 hours. Other services, private endpoints, semantic queries, CU/model
usage and cross-region traffic cost extra. This is not a total solution quote.

The source upload account remains Enabled/Allow with shared keys and anonymous
access disabled. The native template does not redeploy that account. No
Container App, custom bot/application, APIM, officer consumer grant, deletion
or tenant-wide publishing was introduced.

The 27 focused native tests cover rendering, fail-closed private configuration,
safe reuse of immutable definitions, actual agent response shape,
and exact-version evidence integrity. These are local/mocked boundary checks,
not proof of live extraction or cross-officer denials. All native runtime
deployment attempts followed the formal phase-scoped validation workflow.

### Remaining implementation and execution gates

`regiq-native-config-tool-filter-20261117` successfully ran both manifests.
The ACI job completed with exit 0 at `2026-11-17T17:13:13Z`; correlation
`54ea14a1-a766-4913-927b-cd3808396403`. Every definition was applied,
including the version-addressed CU analyzers, private unscheduled indexers,
existing-index IQ sources/bases, MI MCP connections and ordinary prompt agents.
This is configuration proof, not successful case processing.

The original deployment-script runner failed its Azure Files mount and
eventually reported `DeploymentScriptACIProvisioningTimeout`. Contrary to
the earlier assumption, Microsoft's deployment-script documentation requires
shared-key-enabled Files storage. Keys were **not** enabled. The working
`infra/native-config-job.bicep` instead runs Microsoft's digest-pinned
PowerShell image directly in the existing management subnet with no volumes,
exposed ports or public IP. It uses the same scoped authoring identity, with
no source/evidence/approval data grants.

PowerShell was restored through the configured Homebrew distribution;
local syntax parsing now passes. Organization SAML restrictions were not
bypassed. Each changed execution revision passed the complete formal
validation workflow before deployment. Both clients validate live own-store
bindings before writing, reuse only matching ready analyzers/agents and reject
definition drift. The job bounds explicit HTTP 429 retries. The one-tool MCP
allowlist uses the service's canonical `tool_names` object.

Dedicated runner NAT/IP/Storage/private-endpoint resources persist; no
unauthorized deletion was performed. Exact NAT regional pricing remains
unresolved and must not be presented as zero or included in the Search-only
quote. Read-only definition comparison and synthetic native IQ response tests
are separate from the successful configuration execution.

Read-only comparison has now passed for **all nine definitions in each domain**,
including the ready analyzer, exact datasource managed-identity ResourceId,
unscheduled private indexer, IQ source/base and exact agent tool policy.
The actual MCP connections have `isSharedToAll=false`; manifests now request
that narrower scope explicitly. The native allowlist contains exactly
`knowledge_base_retrieve`.

The separate runtime proof completed with exit 0 at `2026-11-17T17:25:02Z`,
under deployment `regiq-native-private-proof-local-mcp-20261117`, correlation
`b44a9f8b-97d5-40cc-8e0f-90a551b48e1f`. Each native agent completed its
administrative synthetic question with exactly one successful IQ tool call:

| Domain | Response ID |
| --- | --- |
| AadiK | `resp_0bce9167ef69ee95006afc8dbd20788190b69ca7d62b048066` |
| AndreL | `resp_0401d2d2c7fd1b04006afc8de635188190b143b25a6cf7d67f` |

Both own Cosmos accounts now also contain their own project-prefixed
`run-state-v1`. The private runner verified exclusively private service DNS
before execution. No case PDF, fabricated approval or officer impersonation
was used. Logs contain configuration policy, IDs and counts, not answer
or evidence bodies. All Azure resources remain provisioned; the administrative
process has terminated.

The approval, extraction, publication and withdrawal gaps described in
earlier revisions are closed by the as-built pipeline above. Withdrawal takes
effect at the next reconcile (at most about 5 minutes plus indexing); answers
already delivered in a Teams conversation are not retracted. The project
keeps no Logic Apps Standard host, so no key-enabled host storage was needed.

## Earlier chat-first assessment - historical, before provisioning

The user approved the updated chat-first markitecture and requested
implementation. Read-only checks reconfirmed the Caldova subscription,
subscription Owner deployment authority and the existing upload foundation.
Native Foundry tooling is ready.

The lower-cost candidate uses two isolated S1 Search services with native
indexers and existing-index IQ knowledge sources: USD 490.56/month for Search
alone at the previously verified retail rate and 730 hours. Other services
and usage are additional; no paid S1 or S2 service was provisioned.

Microsoft documents an ephemeral, VNet-connected ARM deployment-script
runner using Azure Container Instances. This could configure the private
services without a public management exception or a customer Container Apps
application. It has not been provisioned.

Confirmation of spending, the runner and a possible narrower revocation
scope could not be obtained because the user was unavailable. The safe
default preserves the existing strict source-version/revocation requirement.
Native IQ/indexer refresh is asynchronous; no supported native-only
final-answer revocation guard has been verified. Deployment is therefore
blocked, not complete. No new resource, role assignment, workflow or Teams
registration was created during this follow-up.

See the [implementation plan](../.azure/deployment-plan.md) for the recorded
decisions and native capability/API findings.

## Upload foundation

- Subscription: `ME-Caldova63232896-dicasati-1`, commercial Azure.
- Region: `eastus2`.
- [Resource group: rg-regiq-caldova-poc](https://portal.azure.com/#resource/subscriptions/6ab9178f-09bc-45be-ba47-f682147eb1f0/resourceGroups/rg-regiq-caldova-poc/overview)
- Storage: `regiqvqx35xnseaqaw`.
- Blob endpoint: <https://regiqvqx35xnseaqaw.blob.core.windows.net/>.
- Officer containers: `officer-a-pending`, `officer-b-pending`.
- Public network connectivity is **Enabled**, network default **Allow**.
  This permits internet-connected Portal uploads with appropriate Entra roles;
  it does not make containers public.
- Shared-key access and anonymous Blob access are **Disabled**.
- Existing VNet: `regiq-upload-vnet`; Blob private endpoint and private DNS
  remain available for private service connectivity.

The earlier private foundation deployment, `regiq-private-uploads-20261113`,
succeeded. Its historical network-denial tests do not describe the current
public-network setting.

## Canceled deployment and residual resources

`regiq-commercial-bootstrap-20261113` is **Canceled**. This was the rejected
Container Apps approach, not the architecture to implement. Cancellation was
confirmed through the subscription deployment API; it was not a rollback.

Read-only Azure inventory shows these additional resources:

| Resource | Current disposition |
| --- | --- |
| `regiq-chat-environment` | Unwanted Container Apps managed environment; not part of the target. Deletion not yet authorized or performed. |
| `regiqcrvqx35xnseaqaw` | Registry from the rejected approach; not part of the target. Deletion not yet authorized or performed. |
| `regiq-chat-identity` | Identity from the canceled bootstrap; do not assume it has approved PDF-processing rights. |
| `regiq-audit-logs` | Log Analytics workspace; potentially reusable for metadata-only audit. |
| `regiq-ai-vqx35xnseaqaw` | AIServices account, project management disabled. No model deployments returned by the account deployment API. |

There is no deployed Container App or application image in this resource
inventory. The native Search dependencies added later are described above;
this residual-resource list is not the native pilot inventory.

## Implementation target

Follow [the architecture](tax-officer-architecture.md): native Foundry Activity
publishing to Teams, per-officer Blob and Search security domains, private
authorization/extraction tools, version-bound approval and metadata-only audit.
No Container Apps, proxy bot or lexical-search substitution.

The diagram is a target design, **not an as-built inventory**. Public Portal
uploads are the explicit network exception for Storage; private connectivity
for the remaining depicted services must still be implemented and tested.

## Verification still required

- Officer Portal uploads and effective inherited/group role checks.
- Authenticated A-to-B and B-to-A Blob, Search, answer and citation denials.
- Independent approval, exact source-version checks and revocation.
- Native Content Understanding document limits, extraction, timeouts and failures.
- Native Foundry runtime, private networking, regional model and Teams route.
- Real Teams sign-in and conversation behavior, not certificate test callers.
- Retirement of temporary test application credentials and removal of approved
  residual resources.

The earlier 21 local tests cover the prior custom application only. The new
21 native tests are also not live end-to-end proof.

The rejected commercial Bicep templates, generated ARM JSON and Docker build
files have been removed locally. The commercial configuration helper retains
only `retire-tests`; its former deployment and configuration actions are gone.
This does not delete any Azure resources.

Native Foundry tooling/authentication preflight passed. This client could not
reach the existing private Blob endpoint at `10.82.1.4` within five seconds.
The depicted private management/tool path and the explicit machine-reading
authorization gate remain blockers; no public Foundry bootstrap exception or
new PDF-reader grant was applied.

After local corrections, all 21 existing prototype tests passed, the retained
foundation Bicep compiled, all editable diagram formats parsed, and the PNG
was regenerated and visually inspected. All three retired helper actions
reject before Azure execution. None of these checks is a native Teams or
per-officer AI Search integration test.

Standing charges can apply to retained endpoints, registry, managed environment
and logging. No automatic teardown has been performed.

## Low-code and APIM follow-up - 2026-11-14

Read-only Azure inventory still shows the upload foundation and the canceled
deployment's residual resources. The current Azure subscription and tenant
match this report. Storage networking remains Enabled/Allow; shared-key and
anonymous Blob access remain disabled.

The implementation preference is now explicitly native Foundry, AI Search
indexers and Logic Apps, with APIM only for a concrete private API gateway
requirement. APIM's inbound private endpoint and outbound VNet integration
are separate controls; APIM is not required for Foundry's own private endpoint.
See [the architecture](tax-officer-architecture.md#where-apim-fits).

No Azure resources, role assignments, workflow deployments or Teams
registrations were changed during that November 14 follow-up. At that time,
the plan remained Planning. The November 16 implementation/deployment state
at the top of this report supersedes that historical status. Neither APIM
nor the complete low-code PDF-chat pipeline is deployed.
