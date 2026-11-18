# Getting started

## Prerequisites

- An Azure subscription where you can create resources and role assignments (Owner, or Contributor plus Role Based Access Control Administrator).
- Azure CLI 2.60 or later with Bicep, PowerShell 7 and Python 3.
- Microsoft Entra rights to create a security group and read users (for `scripts/sync-officer-group.ps1`).
- A Microsoft 365 tenant where a Teams administrator can upload and assign custom apps.
- Officers who exist as Entra users. Record their object IDs.

All data-plane configuration runs inside the VNet in an Azure Container Instances job (`config-job.bicep`), because every service endpoint is private. Operator tokens are passed as secure parameters only for steps that need a delegated user. Afterwards, redeploy the job without them.

## 1. Set the officers

Edit `config/officers.json`. Each officer has a `key`, `displayName`, `objectId` and a `container` named after the officer, for example `aadik`. Entries with `"optionA": true` also get a per-officer domain.

## 2. Deploy the infrastructure

```bash
RG=rg-regiq-caldova-poc
OPERATOR=<operator object ID>

az deployment sub create -l eastus2 -f infra/bicep/foundation.bicep -p @infra/bicep/foundation.parameters.json

# Per-officer domains: dependencies, then Foundry
az deployment group create -g $RG -f infra/bicep/per-officer-domains.bicep -p @infra/bicep/per-officer-domains.dependencies.parameters.json
az deployment group create -g $RG -f infra/bicep/per-officer-domains.bicep -p @infra/bicep/per-officer-domains.runtime.parameters.json

# Shared agent: dependencies, then Foundry
az deployment group create -g $RG -f infra/bicep/shared-agent.bicep -p operatorObjectId=$OPERATOR deployFoundry=false
az deployment group create -g $RG -f infra/bicep/shared-agent.bicep -p operatorObjectId=$OPERATOR deployFoundry=true

# Configuration job network and identity
az deployment group create -g $RG -f infra/bicep/config-network.bicep -p domainNames='["regiq-a-<suffix>","regiq-b-<suffix>"]'
```

Run each two-phase deployment in order: the second phase needs the roles created by the first.

## 3. Configure the services

Per-officer domains: render the service definitions from the per-officer deployment outputs, then run the configuration job.

```bash
az deployment group show -g $RG -n <per-officer deployment> --query properties.outputs > outputs.json
python3 scripts/per_officer_manifests.py --outputs outputs.json --subscription <subscription ID> --resource-group $RG --output manifests.json
az deployment group create -g $RG -f infra/bicep/config-job.bicep -p manifests=@manifests.json domainNames='[...]'
```

Shared agent: this step creates the analyzer, the ACL index, the knowledge source, the knowledge base, the `UserEntraToken` connection and the agent `caseiq-shared`.

```bash
az deployment group create -g $RG -f infra/bicep/config-job.bicep \
  -p manifests=@manifests.json domainNames='[...]' script=shared sharedSteps=configure \
     sharedConfig='{"name":"regiq-s-<suffix>","operatorObjectId":"<operator>","analyzerId":"case_evidence_<hash>"}'
```

To read the result:

```bash
az container logs -g $RG -n regiq-config-<suffix>-job
```

## 4. Grant officer access

```bash
pwsh scripts/sync-officer-group.ps1        # prints officerGroupObjectId
az deployment group create -g $RG -f infra/bicep/officers.bicep -p officerGroupObjectId=<group ID>
```

## 5. Start ingestion and audit

```bash
az deployment group create -g $RG -f infra/bicep/ingestion.bicep \
  -p domains='[...]' approverObjectId=<approver> \
     sharedIndex='{"searchService":"regiq-s-<suffix>","index":"case-evidence-shared","foundryAccount":"regiq-s-<suffix>","evidenceStorage":"riqs<suffix>","analyzerId":"case_evidence_<hash>","analyzerSha256":"<sha256>"}'
az deployment group create -g $RG -f infra/bicep/audit.bicep -p schedulerName=<scheduler> domains='[...]'
```

Redeploy `ingestion.bicep` only while the ingestion job isn't running:

```bash
az container show -g $RG -n regiq-ingest-<suffix>-job --query containers[0].instanceView.currentState.state
```

## 6. Publish to Teams

**Per-officer agents:**
1. Deploy `infra/bicep/teams-publish-job.bicep` with `operatorToken=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)`.
2. Delete the job container group afterwards.
3. For the app packages, run the configuration job with `teamsPackage=true` and the operator token.

**Shared agent:**
1. Run the configuration job with `script=shared sharedSteps=publish` and the operator token. This registers the bot and prints the app package in base64 (`PACKAGE shared …`).
2. Decode the package to a ZIP.

**Then:**
1. In the Teams admin center, go to **Teams apps → Manage apps → Upload new app** and upload the ZIP.
2. Make the app available to the officers, or to **Case IQ Officers** for the shared agent.
3. Redeploy the configuration job without `operatorToken` or `operatorSearchToken`.

## 7. Test

**Per-officer agents:** run the configuration job with `verifyOnly=true` and `e2eCases` (own-case and cross-officer questions with required and forbidden values).

**Shared agent:**
1. Run the configuration job with `script=shared sharedSteps=test`, `operatorToken` (audience `https://ai.azure.com`) and `operatorSearchToken` (audience `https://search.azure.com`).
2. The test step adds a synthetic record visible only to the operator, runs tests T0–T9 and removes the record. Every line must read `PASS`.
3. Redeploy the configuration job without the tokens.

## Operate

| Task | How |
|---|---|
| Upload | Azure Portal → storage account → **Containers** → own container (for example `aadik`) → **Upload** |
| Approve | Open the PDF → **Blob index tags** → add `approval` = `approved` |
| Withdraw | Remove or change the tag, delete the PDF, or upload a new version |
| Process now | Open the scheduler Logic App → **Run trigger** |
| Chat | Teams → the officer's app → ask a question |

## Add an officer (shared agent)

1. Add the officer to `config/officers.json`.
2. Run `pwsh scripts/sync-officer-group.ps1`.
3. Deploy `infra/bicep/officers.bicep` to create the container and the upload role.
4. Redeploy `infra/bicep/ingestion.bicep` when the ingestion job is idle.

No new Search service, agent or Teams app is needed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Agent tool call fails with `tool_user_error` (shared agent) | The knowledge base MCP URL must use `api-version=2026-08-01-preview`. |
| Teams shows "Invalid Bot" | Publish the agent (`sharedSteps=publish`); packaging alone doesn't register the bot. |
| "App ID already exists" when uploading the ZIP | Use the existing catalog app, or give the package manifest a new `id`. |
| Agent returns `AgentIdentityDisabled` | The agent's Entra identity was deleted, for example by removing the agent in the Microsoft 365 admin center. Restore it from Entra deleted items. |
| Content Understanding rejects a new model deployment | Wait a few minutes after creating the deployment, then rerun `configure`. |
| Redeploying the ingestion job fails | The scheduled run is in progress. Wait until the container is `Terminated`. |
| A new container group stays `Pending` | Reuse the existing configuration job; it takes `script` and step parameters. |

## Clean up

```bash
az group delete -n $RG --yes --no-wait
```

To remove the officer group, delete **Case IQ Officers** in Microsoft Entra ID.
