# Option B fallback: custom engine agent with on-behalf-of retrieval

Status: **design only, not built**. Use it if the option B Teams token path fails. That happens if the shared prompt agent, when invoked from Teams, does not forward the officer's token to the knowledge base, or if any isolation test leaks. See [option-b-shared-agent.md](option-b-shared-agent.md) for the primary design and [option-b-shared-agent-research.md](option-b-shared-agent-research.md) for sources.

## Why it exists

The primary option B relies on Foundry Agent Service doing three things:

1. Receiving the Teams user's identity through Bot Service (`BotServiceRbac`).
2. Exchanging it for a Search token (`UserEntraToken`, Foundry acting as the user).
3. Placing that token in `x-ms-query-source-authorization` on the knowledge base MCP call.

Steps 2 and 3 are documented for direct Foundry callers. The Teams-to-Bot-Service hop is not documented end to end.

The fallback removes that dependency: **our own code** owns every identity step. That gives the strongest guarantee, at the cost of hosting and maintaining code.

## Architecture

```
Officer (Teams)
  │  Teams SSO token (aud = our bot app)
  ▼
Custom engine agent (Microsoft 365 Agents SDK, Azure Container Apps or Foundry hosted agent)
  │  1. validate the Teams activity and the SSO token (issuer, tenant, audience, signature)
  │  2. OBO: exchange the SSO token for a token with aud https://search.azure.com (delegated)
  │  3. POST {search}/knowledgebases('case-evidence-shared')/retrieve?api-version=2026-10-01
  │       Authorization: Bearer <agent managed identity, Search Index Data Reader>
  │       x-ms-query-source-authorization: <officer OBO token>
  │  4. send the retrieved passages and the question to the model
  │     (Foundry model deployment, or the existing prompt agent via structured input, never echoing the token)
  ▼
Answer with citations → Teams
```

It reuses everything option B already deploys:
- the shared ACL index `case-evidence-shared` (native `userIds` = officer object ID);
- the knowledge source and knowledge base;
- the ingestion mirror in `scripts/ingest-native-private.ps1`.

Only the agent front end changes.

## Identity design

| Hop | Credential | Notes |
|---|---|---|
| Teams → agent | Bot Framework / Agents SDK auth plus Teams SSO (`webApplicationInfo` in the manifest) | Validate the tenant (`95287129-…`) and that the `oid` claim is present. |
| Agent → Entra (OBO) | Agent app registration with a **federated credential from its managed identity**; no client secret | Requests the `https://search.azure.com/user_impersonation` delegated scope. An admin grants tenant-wide consent once. |
| Agent → Search (`Authorization`) | Agent managed identity with **Search Index Data Reader** | The caller's RBAC authorization. Officers then need no Search role. |
| Agent → Search (`x-ms-query-source-authorization`) | Officer OBO token | Search evaluates the `userIds` ACL against this token. |
| Agent → model | Agent managed identity with **Foundry User** / OpenAI User | The model never sees the token. |

Rules:
- Never accept a token, object ID or filter from the chat text or from the model. The only identity source is the validated Teams token.
- Never fall back to an unfiltered query or to `x-ms-enable-elevated-read` when OBO fails. Return "case evidence is unavailable".
- Keep cache keys for tokens and OBO results per `oid`. Never share conversation state across officers.
- Belt and braces (optional): also send `filterAddOn: "officer_oid eq '<oid from the validated token>'"` in `knowledgeSourceParams`. A Search ACL failure then still cannot widen results.

## Build steps (when needed)

1. Register the Entra app `caseiq-shared-bot`. Expose `access_as_user` for Teams SSO and add the delegated permission Azure Cognitive Search `user_impersonation`. Grant admin consent. Add a federated credential for a user-assigned managed identity.
2. Create the Azure Bot resource (single-tenant, the same app ID) with the Teams channel.
3. Scaffold with the Microsoft 365 Agents Toolkit (`teams` custom engine agent, Python or C#), plus a Teams SSO OAuth connection on the bot.
4. Host it in Azure Container Apps on the existing VNet, in a new subnet. The container needs:
   - private DNS to Search and Foundry;
   - public ingress only for the Bot Service messaging endpoint.
   Alternative: a Foundry hosted agent, commercial only (hosted agents are not available in Azure Government).
5. Implement `retrieve` with the two headers above (REST `2026-10-01`, GA). Then implement the model call with the retrieved passages and the existing agent instructions.
6. Package the Teams app with `webApplicationInfo` and upload it in the Teams admin center.
7. Run the same isolation suite as option B (T0–T7) plus an OBO-specific negative test: a token for one officer must return only that officer's records, and a malformed or expired token must return no records.

## Trade-offs

| | Primary option B (prompt agent) | Fallback (custom engine) |
|---|---|---|
| Code to own | None (configuration only) | Bot, OBO, retrieval and prompt assembly |
| Identity guarantee | Depends on undocumented Teams → Agent Service user-token flow | Explicit, testable in our code |
| Status | Search ACL GA; `UserEntraToken` + KB MCP tool in preview | Search ACL and OBO GA; Agents SDK GA |
| Microsoft 365 GCC (commercial Azure) | Teams publish of Foundry agents undocumented | Bot Service plus Teams supported in GCC |
| GCC High / DoD (Azure Gov) | Teams publish undocumented | Bot Service is available in Azure Government but channel availability varies; Search ACL undocumented in Azure Gov |
| Operating cost | Search Basic plus Foundry | Same, plus Container Apps (about USD 30–60/month for 1 replica) |

## Decision rule

Use the primary option B if, on the live system, all of these hold:
- the configure-job isolation tests (T0–T7) pass;
- in Teams, officer A sees only A's cases and officer B sees only B's;
- across at least 20 adversarial prompts each, no cross-officer value appears.

Otherwise build this fallback and rerun the same suite.
