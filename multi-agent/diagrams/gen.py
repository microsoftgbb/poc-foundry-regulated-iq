"""Generate Excalidraw diagrams for the zero-trust Foundry multi-agent -> Teams build."""
import json, os

OUT = os.path.dirname(os.path.abspath(__file__))

# FluentUI-aligned palette
BLUE   = ("#0078D4", "#CFE4FA")   # Microsoft / primary
GREEN  = ("#107C10", "#DFF6DD")   # agents / success
PURPLE = ("#5C2D91", "#E8DAEF")   # edge / accent
ORANGE = ("#F7630C", "#FFF4CE")   # data / warning
RED    = ("#D13438", "#FDE7E9")   # blocked / error
GRAY   = ("#1e1e1e", "#F3F2F1")   # neutral

els = []


def reset():
    global els
    els = []


def box(eid, x, y, w, h, label, color, fs=14, fill="hachure", sw=1):
    stroke, bg = color
    els.append({
        "type": "rectangle", "id": eid, "x": x, "y": y, "width": w, "height": h,
        "strokeColor": stroke, "backgroundColor": bg, "fillStyle": fill,
        "strokeWidth": sw, "roundness": {"type": 3},
        "boundElements": [{"type": "text", "id": eid + "_t"}],
    })
    els.append({
        "type": "text", "id": eid + "_t", "containerId": eid,
        "x": x + 8, "y": y + 8, "width": w - 16, "height": h - 16,
        "text": label, "fontSize": fs, "fontFamily": 1,
        "strokeColor": "#000000", "textAlign": "center", "verticalAlign": "middle",
    })


def container(eid, x, y, w, h, label, color, fs=15, sw=2, dash=False):
    stroke, _ = color
    r = {
        "type": "rectangle", "id": eid, "x": x, "y": y, "width": w, "height": h,
        "strokeColor": stroke, "backgroundColor": "transparent", "fillStyle": "solid",
        "strokeWidth": sw, "roundness": {"type": 3},
    }
    if dash:
        r["strokeStyle"] = "dashed"
    els.append(r)
    text(eid + "_lbl", x + 14, y + 10, w - 28, fs * 2.5, label, fs)


def text(eid, x, y, w, h, s, fs=14, align="left"):
    els.append({
        "type": "text", "id": eid, "x": x, "y": y, "width": w, "height": h,
        "text": s, "fontSize": fs, "fontFamily": 1, "strokeColor": "#000000",
        "textAlign": align, "verticalAlign": "top",
    })


def arrow(eid, x, y, pts, color="#1e1e1e", sw=2, dash=False, start=None, end=None):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    a = {
        "type": "arrow", "id": eid, "x": x, "y": y,
        "width": max(xs) - min(xs), "height": max(ys) - min(ys),
        "strokeColor": color, "backgroundColor": "transparent",
        "strokeWidth": sw, "points": pts, "roundness": {"type": 2},
        "endArrowhead": "arrow",
    }
    if dash:
        a["strokeStyle"] = "dashed"
    if start:
        a["startBinding"] = {"elementId": start, "focus": 0, "gap": 2}
    if end:
        a["endBinding"] = {"elementId": end, "focus": 0, "gap": 2}
    els.append(a)


def save(name):
    doc = {"type": "excalidraw", "version": 2, "source": "scout",
           "elements": els, "appState": {"viewBackgroundColor": "#ffffff"}}
    p = os.path.join(OUT, name)
    with open(p, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
    print("wrote", p, len(els), "elements")


# ==========================================================================
# 1. ARCHITECTURE
# ==========================================================================
reset()
text("t1", 40, 20, 1500, 75, "Zero-Trust Foundry Multi-Agent published to Microsoft Teams", 30)
text("t1b", 40, 80, 1500, 45, "Public network access DISABLED on the Foundry account. Teams reaches the agent through the Foundry-managed Activity Protocol endpoint - no APIM, App Gateway or proxy in the path.", 14)

box("key", 40, 125, 1600, 50,
    "KEY:  one property  ->  agent_endpoint.protocol_configuration.activity.enable_m365_public_endpoint = true", ORANGE, 15)

# Zone A - public
container("zA", 40, 210, 300, 330, "PUBLIC INTERNET", BLUE)
box("teams", 70, 265, 240, 100, "Microsoft Teams\nclient", BLUE, 15)
box("copilot", 70, 395, 240, 100, "Microsoft 365\nCopilot", BLUE, 15)

# Zone B - edge
container("zB", 380, 210, 330, 560, "FOUNDRY EDGE (no APIM)", PURPLE)
box("bot", 405, 265, 280, 115,
    "Azure Bot Service\nbot-invoice-orchestrator\nTeams channel\nPNA Disabled - SingleTenant", PURPLE, 13)
box("act", 405, 410, 280, 155,
    "Activity Protocol\npublic endpoint\n\nenable_m365_public_endpoint\n= true\n\nservice-managed\nsource-IP filtering", PURPLE, 13)
box("auth", 405, 595, 280, 100,
    "authorization_schemes\nEntra + BotServiceRbac\n(network != authorization)", GRAY, 13)

# Zone C - private
container("zC", 760, 210, 880, 840, "PRIVATE - VNet 192.168.0.0/16 (no public egress)", GREEN)

container("acct", 785, 275, 585, 510, "Foundry account  <account>   (publicNetworkAccess: Disabled)", GREEN, 14)
text("proj", 800, 315, 400, 40, "project: <project>", 13)

box("orch", 810, 355, 225, 135,
    "invoice-orchestrator\nv13\n\nCHAT FRONT-END\n(the only agent\nTeams talks to)", GREEN, 13)
box("ext", 1090, 345, 255, 75, "invoice-extractor\nA2A sub-agent", GREEN, 13)
box("val", 1090, 435, 255, 75, "invoice-validator\nA2A sub-agent", GREEN, 13)
box("apr", 1090, 525, 255, 75, "invoice-approver\nA2A sub-agent", GREEN, 13)
box("model", 810, 520, 225, 75, "gpt-4.1\nGlobalStandard", BLUE, 13)
box("caph", 810, 625, 225, 90, "capability host\n@aml_aiagentservice\n(ACA micro-VMs)", GRAY, 12)
text("a2albl", 1045, 400, 60, 60, "A2A", 13)

# right column
box("subnet", 1395, 285, 225, 130,
    "agent-subnet\n192.168.0.0/24\ndelegated to\nMicrosoft.App/\nenvironments", GREEN, 12)
box("dns", 1395, 435, 225, 175,
    "Private DNS zones\nprivatelink.services.ai\nprivatelink.openai\nprivatelink.documents\nprivatelink.blob\nprivatelink.search", ORANGE, 12)
box("jump", 1395, 630, 225, 110, "jumpbox VM\n+ Azure Bastion\n(admin / publish)", GRAY, 12)

container("pe", 785, 810, 585, 215, "pe-subnet 192.168.1.0/24  -  Private Endpoints", ORANGE, 14)
box("cosmos", 805, 865, 175, 135, "Azure\nCosmos DB\n>= 3000 RU/s\n(threads)", ORANGE, 12)
box("stor", 995, 865, 175, 135, "Azure\nStorage\n(files)", ORANGE, 12)
box("srch", 1185, 865, 175, 135, "Azure AI\nSearch\nEntra auth\n(vectors)", ORANGE, 12)

# arrows
arrow("a1", 315, 310, [[0, 0], [85, 5]], BLUE[0], 2, end="bot")
arrow("a2", 315, 440, [[0, 0], [85, -30]], BLUE[0], 2)
arrow("a3", 545, 385, [[0, 0], [0, 20]], PURPLE[0], 2)
arrow("a4", 690, 480, [[0, 0], [115, -50]], PURPLE[0], 3, end="orch")
arrow("a5", 1040, 400, [[0, 0], [45, -15]], GREEN[0], 2, end="ext")
arrow("a6", 1040, 425, [[0, 0], [45, 45]], GREEN[0], 2, end="val")
arrow("a7", 1040, 450, [[0, 0], [45, 110]], GREEN[0], 2, end="apr")
arrow("a8", 920, 495, [[0, 0], [0, 20]], BLUE[0], 2)
arrow("a9", 1075, 790, [[0, 0], [0, 60]], ORANGE[0], 2, dash=True)

text("n1", 715, 520, 90, 60, "private", 12)
text("n2", 1085, 795, 200, 40, "threads / files / vectors", 11)
save("01-architecture.excalidraw")

# ==========================================================================
# 2. DATA FLOW
# ==========================================================================
reset()
text("t2", 40, 20, 1500, 75, "Data Flow - one Teams question -> three A2A sub-agents -> one answer", 30)
text("t2b", 40, 80, 1500, 45, "Every hop right of step 3 stays inside the VNet. The Foundry account never accepts public data-plane traffic.", 14)

lane_y = 160
box("s1", 40, lane_y, 250, 130,
    "1  USER\nTeams chat\n\n\"Contoso INV-4471,\nPO-88213 ...\"", BLUE, 13)
box("s2", 330, lane_y, 250, 130,
    "2  BOT SERVICE\nTeams channel routes\nthe activity\n\nBotServiceRbac +\nEntra validation", PURPLE, 13)
box("s3", 620, lane_y, 250, 130,
    "3  ACTIVITY ENDPOINT\nFoundry-managed,\nsource-IP filtered\n\nonly M365 ranges\nadmitted", PURPLE, 13)
box("s4", 910, lane_y, 250, 130,
    "4  ORCHESTRATOR\ninvoice-orchestrator\nv13 (pinned)\n\nplans the delegation", GREEN, 13)

arrow("f1", 295, lane_y + 65, [[0, 0], [30, 0]], GRAY[0], 2)
arrow("f2", 585, lane_y + 65, [[0, 0], [30, 0]], GRAY[0], 2)
arrow("f3", 875, lane_y + 65, [[0, 0], [30, 0]], GRAY[0], 2)

# fan out
text("fan", 910, 320, 400, 40, "5   A2A delegation  (agentic-identity token)", 16)

box("d1", 910, 370, 300, 105,
    "invoice-extractor\n-> JSON: vendor, PO,\nline items, totals", GREEN, 13)
box("d2", 910, 495, 300, 105,
    "invoice-validator\n-> qty x price, subtotal,\ntotal, PO conformity", GREEN, 13)
box("d3", 910, 620, 300, 105,
    "invoice-approver\n-> APPROVE / HOLD /\nREJECT + rationale", GREEN, 13)

arrow("ff1", 1035, 295, [[0, 0], [0, 70]], GREEN[0], 2)
arrow("ff2", 1210, 422, [[0, 0], [60, 0], [60, 125], [0, 125]], GREEN[0], 2, dash=True)
arrow("ff3", 1210, 547, [[0, 0], [60, 0], [60, 125], [0, 125]], GREEN[0], 2, dash=True)

text("seq", 1290, 470, 260, 120,
    "sequential:\nextract -> validate\n-> approve", 13)

# back to user
box("s6", 380, 495, 420, 230,
    "6  ANSWER RENDERED IN TEAMS\n\nInvoice Review Summary\nVendor / Invoice / PO\n\nFindings:\n- all calculations accurate\n- standing desks NOT on PO-88213\n\nDECISION: HOLD\nAction required: confirm authorization", GREEN, 13)
arrow("f6", 900, 610, [[0, 0], [-95, 0]], GREEN[0], 3, end="s6")

# data plane
container("dp", 40, 370, 300, 355, "data plane (private endpoints)", ORANGE, 14)
box("dpc", 65, 425, 250, 80, "Cosmos DB\nthreads + run state", ORANGE, 12)
box("dps", 65, 525, 250, 80, "Storage\nfiles", ORANGE, 12)
box("dpa", 65, 625, 250, 80, "AI Search\nvectors", ORANGE, 12)
arrow("dpar", 900, 700, [[0, 0], [-560, 0]], ORANGE[0], 2, dash=True)
text("dpt", 420, 740, 420, 40, "all agent state persisted in your tenant", 12)

save("02-dataflow.excalidraw")

# ==========================================================================
# 3. COMPONENT
# ==========================================================================
reset()
text("t3", 40, 20, 1500, 75, "Component & Identity Model", 30)
text("t3b", 40, 80, 1500, 45, "Which resource talks to which, and the exact role each identity needs. The identity rotation at publish time is the classic gotcha.", 14)

box("g", 40, 130, 1600, 75,
    "GOTCHA: publishing gives the agent a NEW unique identity. Grant that identity Foundry Agent Consumer\n"
    "on the project or every A2A call fails with 'Failed to fetch agent card: 404'.", RED, 14)

# M365 tier
container("c1", 40, 240, 380, 300, "Microsoft 365 tier", BLUE)
box("c1a", 65, 295, 330, 80, "Microsoft Teams / M365 Copilot", BLUE, 13)
box("c1b", 65, 395, 330, 115,
    "Azure Bot Service\nbot-invoice-orchestrator\nmsaAppId = agent client_id\nkind: azurebot, SingleTenant", BLUE, 12)

# Foundry tier
container("c2", 460, 240, 700, 620, "Microsoft Foundry  (Microsoft.CognitiveServices / AIServices)", GREEN)
box("c2a", 485, 295, 315, 130,
    "Foundry account\n<account>\n\npublicNetworkAccess: Disabled\nnetworkAcls: Deny", GREEN, 12)
box("c2b", 825, 295, 310, 130,
    "project  <project>\n\ncapability host\n{account}@aml_aiagentservice", GREEN, 12)
box("c2c", 485, 450, 315, 150,
    "invoice-orchestrator  v13\n\nPromptAgentDefinition\ntools = 3 x A2APreviewTool\n(project_connection_id)\n\nidentity <orchestrator-mi>", GREEN, 12)
box("c2d", 825, 450, 310, 150,
    "sub-agents (x3)\nextractor / validator / approver\n\nagent_card + protocols\n['responses','a2a']\n\nshared identity <project-mi>", GREEN, 12)
box("c2e", 485, 625, 650, 95,
    "project connections (x3)   kind: RemoteA2A   auth: AgenticIdentityToken   audience: https://ai.azure.com\n"
    "target: .../agents/{name}/endpoint/protocols/a2a      NO AgentCardPath metadata", ORANGE, 12)
box("c2f", 485, 745, 650, 90,
    "model deployment  gpt-4.1  GlobalStandard  (shared by every project in the account)", BLUE, 13)

# data tier
container("c3", 1200, 240, 440, 340, "BYO data plane (private endpoints)", ORANGE)
box("c3a", 1225, 295, 390, 75, "Azure Cosmos DB   >= 3000 RU/s", ORANGE, 12)
box("c3b", 1225, 390, 390, 75, "Azure Storage   (blob)", ORANGE, 12)
box("c3c", 1225, 485, 390, 75, "Azure AI Search   aadOrApiKey", ORANGE, 12)

# identity / rbac
container("c4", 1200, 610, 440, 450, "Identity & RBAC", PURPLE)
box("c4a", 1225, 665, 390, 110,
    "orchestrator identity (post-publish)\nFoundry User\nFoundry Agent Consumer  <- required", RED, 12)
box("c4b", 1225, 790, 390, 100,
    "sub-agent shared identity\nFoundry User\nFoundry Agent Consumer", PURPLE, 12)
box("c4c", 1225, 905, 390, 135,
    "deployer (human)\nFoundry Account Owner\n+ Role Based Access Administrator\n(VNet-join alone is NOT enough)", PURPLE, 12)

# network tier
container("c5", 40, 580, 380, 480, "Network", GRAY)
box("c5a", 65, 635, 330, 105, "agent-vnet 192.168.0.0/16\nagent-subnet /24 delegated\nMicrosoft.App/environments", GREEN, 12)
box("c5b", 65, 760, 330, 85, "pe-subnet /24\n4 private endpoints", ORANGE, 12)
box("c5c", 65, 865, 330, 85, "6 privatelink DNS zones\nlinked to the VNet", ORANGE, 12)
box("c5d", 65, 970, 330, 70, "jumpbox + Bastion\n(publish + admin)", GRAY, 12)

arrow("k1", 230, 380, [[0, 0], [0, 15]], BLUE[0], 2)
arrow("k2", 400, 450, [[0, 0], [80, 0]], BLUE[0], 2)
arrow("k3", 640, 430, [[0, 0], [0, 20]], GREEN[0], 2)
arrow("k4", 800, 520, [[0, 0], [25, 0]], GREEN[0], 2)
arrow("k5", 1140, 360, [[0, 0], [80, 0]], ORANGE[0], 2, dash=True)
text("k4t", 790, 415, 120, 40, "A2A", 13)

save("03-component.excalidraw")
print("done")


