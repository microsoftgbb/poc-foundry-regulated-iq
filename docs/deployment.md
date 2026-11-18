# Deployment: as built, runbook and option A results

Checked: 2026-11-17 UTC.

**The diagram is implemented end to end in both officer domains and verified
live: Portal upload -> own Blob -> Content Understanding custom analyzer ->
approval -> private indexing -> Foundry IQ -> native agent -> Teams.**
Teams chat itself needs each officer to sign in; see the runbook below.

Option B (one shared agent, per-officer document ACLs) runs alongside this
pilot in `regiq-s-3a2hsmj55wycu`; see [option-b-shared-agent.md](option-b-shared-agent.md).
The same ingestion job also runs option B's shared pipeline for every officer in
[`infra/officers.json`](../infra/officers.json).

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

Shared scope lists each agent under **Your agents** only for the publisher.
Officers get the app from the Teams admin center (upload the package from the
package step, then assign it to them). BotServiceRbac still rejects any user
without `Foundry Agent Consumer` on that officer's project.

## Resource inventory

Resource group `rg-regiq-caldova-poc`. Foundry, Cosmos DB and Storage are in East US 2. Search is in East US, because East US 2 had no Search capacity.

| Purpose | Resources | Template |
| --- | --- | --- |
| Upload foundation | Storage `regiqvqx35xnseaqaw` (Entra-only, shared keys off), VNet `regiq-upload-vnet` (10.82.0.0/16), Blob private endpoint | `main.bicep`, `private-uploads.bicep` |
| Option A domains | Per officer: Foundry `regiq-{a,b}-…` with project `caseiq`, Search S1, evidence store `riq{a,b}…`, runtime store `rih{a,b}…`, Cosmos DB serverless, agent subnet `native-agent-{a,b}` | `native-iq.bicep`, `native/domain.bicep` |
| Option B domain | Foundry `regiq-s-…` with project `caseiq`, Search Basic (no keys, ACL index), evidence store `riqs…`, runtime store `rihs…`, Cosmos DB serverless, agent subnet `native-agent-s` | `native-shared.bicep` |
| Officer access | Upload containers, per-officer upload role, group **Case IQ Officers** roles | `officers.bicep`, `scripts/sync-officer-group.ps1` |
| Private configuration | NAT gateway, subnet `native-config`, identity `regiq-config-…`, ACI job `regiq-config-…-job` | `native-config-network.bicep`, `native-config-job.bicep` |
| Ingestion | Identity and ACI job `regiq-ingest-…`, Logic App scheduler, custom roles (Ingestion Reader, Case Approver, Ingestion Starter) | `native-ingest.bicep` |
| Audit | Diagnostic settings to `regiq-audit-logs` (metadata only) | `native-audit.bicep` |

## Deployment order

```bash
RG=rg-regiq-caldova-poc
az deployment sub create -l eastus2 -f infra/main.bicep -p @infra/main.parameters.json
az deployment group create -g $RG -f infra/native-iq.bicep -p @infra/native-iq.parameters.json          # dependencies
az deployment group create -g $RG -f infra/native-iq.bicep -p @infra/native-iq-runtime.parameters.json  # Foundry
az deployment group create -g $RG -f infra/native-shared.bicep -p operatorObjectId=<oid> deployFoundry=false
az deployment group create -g $RG -f infra/native-shared.bicep -p operatorObjectId=<oid> deployFoundry=true
az deployment group create -g $RG -f infra/native-config-network.bicep -p domainNames='["regiq-a-…","regiq-b-…"]'
python3 scripts/native_iq.py --outputs <native-iq outputs.json> --subscription <sub> --resource-group $RG --output manifests.json
az deployment group create -g $RG -f infra/native-config-job.bicep -p manifests=@manifests.json domainNames=…   # option A configure
az deployment group create -g $RG -f infra/native-config-job.bicep -p manifests=… domainNames=… script=shared sharedSteps=configure sharedConfig=…
pwsh scripts/sync-officer-group.ps1
az deployment group create -g $RG -f infra/officers.bicep -p officerGroupObjectId=<group id>
az deployment group create -g $RG -f infra/native-ingest.bicep -p domains=… approverObjectId=<oid> sharedIndex=…
az deployment group create -g $RG -f infra/native-audit.bicep -p schedulerName=<scheduler> domains=…
```

The configure, test, package and publish steps that need the operator's token pass it as a secure parameter. Afterwards, always redeploy the config job without tokens.

## Leftovers in the resource group (not part of this solution)

These resources are from an earlier, cancelled chat-first approach and are no longer used:
- `regiq-chat-environment` and `regiq-chat-identity`
- `regiqcrvqx35xnseaqaw`
- `regiq-ai-vqx35xnseaqaw`
- the config runner's Files storage `riqc…`, its private endpoint, and the `regiq-config-…` deployment script

They can be deleted once someone confirms nothing else depends on them.
