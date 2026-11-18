# Fallback: custom front end over the shared index

Status: **design only, not built.**

This design keeps the shared index and its ACLs, but replaces the Foundry prompt agent with our own front end. That front end handles the officer's sign-in and the token exchange to Search itself.

## Flow

```
Officer (Teams or web)
  │  sign-in token (audience: the front end's app registration)
  ▼
Front end (Microsoft 365 Agents SDK or a web app, private ingress)
  │  1. validate the token: issuer, tenant, audience, signature, oid
  │  2. on-behalf-of exchange for a delegated Search token
  │  3. POST {search}/knowledgebases('case-evidence-shared')/retrieve?api-version=2026-10-01
  │       Authorization: <front end managed identity, Search Index Data Reader>
  │       x-ms-query-source-authorization: <officer's delegated token>
  │  4. send the retrieved passages and the question to the model deployment
  ▼
Answer with citations
```

## Identities

| Hop | Credential |
|---|---|
| Officer → front end | Entra sign-in for the front end's app registration |
| Front end → Entra (on-behalf-of) | App registration with a federated credential from the front end's managed identity, and the delegated `https://search.azure.com/user_impersonation` permission with admin consent |
| Front end → Search (`Authorization`) | Managed identity with Search Index Data Reader |
| Front end → Search (`x-ms-query-source-authorization`) | The officer's delegated token |
| Front end → model | Managed identity with Cognitive Services OpenAI User |

## Rules

- Take identity only from the validated sign-in token, never from chat text or model output.
- If the token exchange fails, return "case evidence is unavailable". Never fall back to an unfiltered or elevated query.
- Partition caches and conversation state by the officer's object ID.

## Tests

Run the shared-agent isolation tests (T0–T9) against the front end, plus these checks:
- an expired or malformed token returns no records;
- one officer's token never returns another officer's records.
