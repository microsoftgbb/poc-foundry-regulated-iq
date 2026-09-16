# Customer demo script

**Target length:** 12–15 minutes.
**Arc:** show the old cost → show the one-line change → prove both halves of the claim.

**Before you start, have open:**

- Azure portal on the Foundry account's **Networking** blade
- A terminal on your laptop (public internet)
- A terminal on a VM inside the VNet (or an RDP/Bastion session)
- Teams, with the published agent pinned

---

## Scene 1 — Name the problem (2 min)

> "Your Foundry Agent is inside the VNet, which is exactly where your security team wants it.
> But Teams and Microsoft 365 Copilot are public-network products — they can only call endpoints
> that are routable from the internet. That tension is the entire problem we're solving today."

**Show:** `diagrams/01-before-apim.png`. Walk the chain left to right and name the owner of each hop.

**Ask:** "Who on your team owns the APIM policy and the proxy code today, and how long is a change
cycle through them?" The answer sizes the value of what comes next.

---

## Scene 2 — Show the old cost (2 min)

- APIM instance: licence, IaC, policy, and a team that owns it
- Public ingress or Application Gateway: another WAF, another certificate story
- Container App proxy: your code, translating Activity Protocol to Responses, with its own release cycle
- Four more identities, four more RBAC conversations, four more things to patch

> "None of this is differentiating work. It is plumbing between your agent and your users."

---

## Scene 3 — The change (3 min)

**Show:** `diagrams/02-after-m365-endpoint.png`, then the live PATCH body.

```jsonc
"protocol_configuration": {
  "responses": {},
  "activity": { "enable_m365_public_endpoint": true }
},
"authorization_schemes": [
  { "type": "Entra" },
  { "type": "BotServiceRbac" }
]
```

> "Foundry opens the Activity Protocol route — and only that route — to Microsoft 365, using
> source-IP filtering it manages. Your account still has public network access disabled.
> Your agent never leaves the VNet."

**Pre-empt the objection:**

> "Before your security architect asks — this is not anonymous access. Requests from an allowed
> range still have to pass Bot Service or Entra authentication and your RBAC. That is why
> `BotServiceRbac` stays in the list."

---

## Scene 4 — Prove it is private (3 min)

Run from your laptop, on the public internet. Both should fail:

```text
GET  {endpoint}/agents/{agent}?api-version=v1                       -> 403
POST {endpoint}/agents/{agent}/endpoint/protocols/openai/responses  -> 403
```

Then run the identical calls from a VM inside the VNet. **Show the DNS resolution first** — it is
the most convincing single frame of the demo:

```text
Resolve-DnsName <account>.services.ai.azure.com
  -> <account>.privatelink.services.ai.azure.com   CNAME
  -> 10.0.1.6                                      A

GET  .../agents/{agent}   -> 200 OK
POST .../responses        -> 200 OK
```

> "Same URL, same token. The only variable is where the request came from."

`scripts/07-verify.ps1` runs all of this in one pass — run it in both locations.

---

## Scene 5 — Prove Teams still works (3 min)

Switch to Teams and open the published agent. Ask it a question that makes it describe its own
path — it makes the architecture audible instead of abstract.

```text
Prompt: "How are you connected?"
```

Expected answer, in the agent's own words: it is reached through the Foundry-managed Activity
Protocol public endpoint with service-managed source IP filtering, with no APIM or proxy in the path.

> "Responses is 403 from the internet. Teams works. That is the whole feature."

**Optional flourish:** run `scripts/06-toggle-public-access.ps1 -Mode Public`, wait ~30s, re-run
the laptop test to show `200`, then flip back to `-Mode Private` and show `403` again — all while
Teams keeps answering without a re-publish.

---

## Scene 6 — Close and scope (2 min)

- If the only reason APIM was in the design was bridging Microsoft 365 to a private agent — **remove it**
- If APIM is also doing rate limiting, monetisation, non-Teams ingress, or fronting other APIs — **keep it**
- Teams itself stays a public-network product. If that is a hard blocker, no Foundry setting fixes it

> "Let's pick one agent that is currently blocked behind the APIM bridge and run this pattern
> against it in your dev subscription this week."

---

## Questions you will get

| Question | Answer |
| --- | --- |
| "So our agent endpoint is public now?" | Only the Activity Protocol route, and only to Microsoft-managed source ranges. Management APIs and all other protocols stay private. Authentication and RBAC still apply on top. |
| "Can we see or control the IP allow-list?" | No. Foundry manages it as a service control, which is the point — you do not maintain it. Treat it as defense in depth layered under Entra and Bot Service auth. |
| "Does this work for Microsoft 365 Copilot too?" | Yes. The same Activity Protocol route serves Teams and Microsoft 365 Copilot. |
| "What if we want the whole path private?" | Not possible today. Teams and M365 require internet-routable endpoints. Reset this expectation early rather than at design review. |
| "Can we do this in the portal?" | Not yet. REST API or SDK only. Portal support is expected to follow. |
| "What happens if we omit a protocol in the PATCH?" | It is dropped. The PATCH replaces the whole bag. Always re-send `responses` and `Entra` alongside your additions. |
| "Does toggling public access break the Teams app?" | No. `enable_m365_public_endpoint` stays set and simply goes dormant while public access is on. No re-publish either direction. |
