# Setup guide

Build the multi-agent A2A system on a network-secured Foundry project and publish the
orchestrator to Microsoft Teams.

Total time: **~45 minutes**, most of it waiting on the network-secured Foundry deployment and
RBAC propagation.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Foundry project | A **network-secured (standard) agent setup** with a delegated agent subnet, private endpoints and BYO Cosmos DB / Storage / AI Search. See [`virtual-networks`](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks) or [template 15](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup). |
| Model deployment | e.g. `gpt-4.1` GlobalStandard, in the same account. |
| Roles (you) | **Foundry Account Owner** + **Role Based Access Administrator** (or Owner) at subscription scope, and **Foundry Project Manager** on the project to create connections. A custom role that only grants VNet join is *not* enough. |
| Jump box | A VM in the VNet (plus Azure Bastion), or VPN / ExpressRoute. Required once public access is disabled. |
| Tooling | Azure CLI >= 2.60, PowerShell 7+, Python 3.10+, `azd` with the `azure.ai.connections` extension. |
| Providers | `Microsoft.CognitiveServices`, `Microsoft.App`, `Microsoft.BotService`, plus the rest listed in the private-networking doc. |

Install the Python packages where you will run steps 4 and 7:

```bash
pip install "azure-ai-projects>=2.5.0" azure-identity openai
```

---

## Step 0 — Configure

```powershell
cd multi-agent/scripts
Copy-Item 00-variables.sample.ps1 00-variables.ps1
```

Fill in `00-variables.ps1` with your subscription, tenant, resource group, Foundry account and
project. The file is gitignored — it never gets committed.

```powershell
az login
az account set --subscription "<your-subscription-id>"
az provider register --namespace Microsoft.BotService
```

Set the same values for the Python scripts:

```powershell
$env:FOUNDRY_PROJECT_ENDPOINT = "https://<account>.services.ai.azure.com/api/projects/<project>"
$env:FOUNDRY_MODEL = "gpt-4.1"
```

> **Where to run what.** If public network access is already disabled on the account, every
> step that touches the **data plane** (`/agents/...`) must run from inside the VNet — the jump
> box. Control-plane work (`az deployment`, role assignments) can run from anywhere.

---

## Step 1 — Create the three sub-agents

```powershell
./01-create-subagents.ps1
```

Creates `invoice-extractor`, `invoice-validator` and `invoice-approver` as persistent prompt
agents. They are ordinary agents at this point — nothing A2A about them yet.

Confirm they appear under **Build → Agents** in the Foundry portal.

> `POST /agents/{name}/versions` requires the body wrapped in a **`definition`** object.
> Omitting it returns `400 invalid_payload — Required property 'definition' is missing`.

---

## Step 2 — Enable incoming A2A on each sub-agent

```powershell
./02-enable-incoming-a2a.ps1
```

This PATCHes each sub-agent to publish an **`agent_card`** and add `a2a` to
`agent_endpoint.protocols`.

**Both halves are required.** Adding the protocol without a card leaves the card
unresolvable, and the caller later fails with `Failed to fetch agent card: 404`. The script
prints the A2A endpoint of each sub-agent — you will use those as connection targets next.

Verify (from inside the VNet):

```powershell
$tok = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
curl.exe -H "Authorization: Bearer $tok" `
  "$env:FOUNDRY_PROJECT_ENDPOINT/agents/invoice-extractor/endpoint/protocols/a2a/agentCard/v0.3?api-version=v1"
```

A `200` with the agent card JSON means the target side is ready.

---

## Step 3 — Create the A2A project connections

```powershell
./03-create-a2a-connections.ps1
```

Creates one `RemoteA2A` connection per sub-agent with `agentic-identity` auth and audience
`https://ai.azure.com`.

Two things to get right:

- Connections must be created with **`azd ai connection create`** (or the portal). The Python
  SDK's `project.connections` is read-only.
- **Do not** pass `--metadata "AgentCardPath=..."`. For a Foundry-agent target Foundry resolves
  its own default path; supplying one returns *"Agent card path is invalid for a Foundry
  agent."*

Check the result:

```powershell
azd ai connection list
```

You should see three `RemoteA2A` / `AgenticIdentityToken` entries.

---

## Step 4 — Create the orchestrator

```powershell
python 04-create-orchestrator.py
```

Creates (or versions) `invoice-orchestrator` with the three connections attached as
`A2APreviewTool` entries referencing `project_connection_id`.

**Note the version number it prints** — you will pin it in step 8.

---

## Step 5 — Grant the agent identity its roles

```powershell
# discover the current identity
./06-show-identity.ps1

# grant it the roles (repeat for the sub-agents' shared identity if different)
./05-grant-agent-identity.ps1 -PrincipalId "<principal-id-from-06>"
```

The calling agent needs **`Foundry Agent Consumer`** (and `Foundry User`) on the project, or it
cannot read the target agents' cards.

Wait **2–3 minutes** for RBAC to propagate.

> ### Read this before you debug anything
>
> Before publishing, all agents in a project share one identity. **After publishing, the
> published agent gets a brand-new identity with no role assignments.** If A2A worked and then
> stopped right after you wired up the Bot Service or published, this is why. Run
> `06-show-identity.ps1` again — the principal ID will have changed — and re-run step 5 against
> the new one.

---

## Step 6 — Verify delegation

```powershell
python 07-invoke-orchestrator.py
```

Expected: a three-part answer (extraction, validation, decision) ending in `HOLD` or `REJECT`,
because the sample invoice contains an item that is not on the referenced PO.

If you get `Failed to fetch agent card: 404` → step 5 (identity).
If you get `Agent card path is invalid for a Foundry agent` → remove the card path (step 3).

Do not continue until this works. Publishing a broken orchestrator to Teams only makes the
feedback loop slower.

---

## Step 7 — Deploy the Bot Service

Use the ARM template in the parent folder, passing the orchestrator's
`instance_identity.client_id` (from `06-show-identity.ps1`) as `msaAppId`:

```powershell
$activity = "$ProjectEndpoint/agents/invoice-orchestrator/endpoint/protocols/activityProtocol?api-version=2025-05-15-preview"

az deployment group create -g <resource-group> `
  --template-file ../../infra/bot-service.json `
  --parameters botName=bot-invoice-orchestrator `
               displayName="Invoice Orchestrator" `
               msaAppId=<client-id> `
               tenantId=<tenant-id> `
               endpoint=$activity
```

Copy the **Bot ARM ID** from the output.

Then re-check the identity — deploying the bot can rotate it:

```powershell
./06-show-identity.ps1
```

---

## Step 8 — Pin the version and open the M365 endpoint

```powershell
./08-enable-m365-endpoint.ps1 -Version <version-from-step-4>
```

Sets `activity.enable_m365_public_endpoint = true` and pins traffic to the version that carries
the A2A tools.

> **Pin deliberately.** It is easy to enable the endpoint while the selector still points at an
> older version with no A2A tools, then wonder why Teams answers but never delegates.

> **The PATCH replaces `protocol_configuration` and `authorization_schemes` wholesale.**
> Everything the endpoint must retain has to be in the body — including `responses` and
> `Entra`. The script sends the full set; keep it that way if you customise it.

Match the auth scheme to your publish scope:

| `publishScope` | Visibility | Authorization scheme | Admin approval |
|---|---|---|---|
| `Shared` | Only you — **Your agents** | `BotServiceRbac` | No |
| `Tenant` | Whole org — **Built by your org** | `BotServiceTenant` | Yes, M365 admin center |

---

## Step 9 — Publish to Teams

Run this **from the jump box**, signed in as yourself:

```powershell
az login
./09-publish-to-m365.ps1 -BotServiceArmId "<bot-arm-id-from-step-7>"
```

A successful publish returns a `titleId` and a `teamsAppId`.

> **Why the jump box.** Publishing performs an on-behalf-of exchange with the Microsoft 365
> titles service, which needs a **delegated user token** — a managed identity cannot do it. On a
> network-injected account the call must also originate inside the VNet. Only a signed-in user
> on an in-VNet host satisfies both. An IP allowlist does not help: the agent data plane is
> bound to the VNet by design.

Then re-run step 5 one last time if `06-show-identity.ps1` shows a new principal ID.

---

## Step 10 — Try it in Teams

Open **Teams → Apps → Your agents → Invoice Orchestrator** and paste:

```
Contoso Office Supplies, INV-4471, PO PO-88213. 10 Ergonomic chair @220=2200;
4 Standing desk @610=2440; 25 Notebook @12=300. Subtotal 4940, Tax 419.90,
Shipping 75, Total 5434.90. Standing desks were NOT on PO-88213.
```

You should get an invoice review summary with findings and a **HOLD** decision — produced by
four agents behind a Foundry account whose public network access is disabled.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Failed to fetch agent card: 404` | Calling identity lacks access to the target agent — usually after a publish rotated the identity | `06-show-identity.ps1`, then `05-grant-agent-identity.ps1` with the new principal ID; wait 2–3 min |
| `Agent card path is invalid for a Foundry agent` | A card path was supplied on the tool or connection | Remove `agent_card_path` / `AgentCardPath` and let Foundry resolve its own |
| `Foundry A2A targets require Microsoft Entra authentication` | Tool points at a raw URL instead of a connection, or the connection has no Entra auth | Use `project_connection_id` on a `RemoteA2A` connection with `agentic-identity` |
| `400 invalid_payload — 'definition' is missing` | Version payload not wrapped | Wrap the agent body in a `definition` object |
| `Role 'Azure AI User' doesn't exist` | RBAC rename rolled out | Use `Foundry User` / `Foundry Project Manager` / `Foundry Agent Consumer` |
| Teams answers but never delegates | Endpoint pinned to a version without A2A tools | Re-run `08-enable-m365-endpoint.ps1` with the correct version |
| Publish fails with `Could not obtain a delegated (on-behalf-of) user token` | Running as a managed identity or service principal | Run from the jump box after `az login` as a user |
| `403 Access denied due to Virtual Network/Firewall rules` from your laptop | Expected — the account is private | Run from inside the VNet; an IP allowlist does not cover the agent data plane |
| Connection create fails from the Python SDK | `project.connections` is read-only | Use `azd ai connection create` or the portal |

---

## Cleanup

```powershell
# remove the agents and connections but keep the Foundry account
foreach ($a in @("invoice-orchestrator","invoice-extractor","invoice-validator","invoice-approver")) {
    az rest --method delete --url "$ProjectEndpoint/agents/$a`?api-version=v1" --resource https://ai.azure.com
}
foreach ($c in @("conn-invoice-extractor","conn-invoice-validator","conn-invoice-approver")) {
    azd ai connection delete $c
}
az deployment group delete -g <resource-group> --name botdeploy
```

To tear down everything including the network-secured Foundry account, delete the resource
group — and remember to **purge** the account if you intend to reuse the same delegated subnet.
