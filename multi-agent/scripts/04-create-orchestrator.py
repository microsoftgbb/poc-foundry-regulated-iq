"""
Create the orchestrator agent with the three sub-agents attached as A2A tools.

Prereqs:
  pip install "azure-ai-projects>=2.5.0" azure-identity openai
  az login   (or run with a managed identity that has Foundry User on the project)

Env:
  FOUNDRY_PROJECT_ENDPOINT   https://<account>.services.ai.azure.com/api/projects/<project>
  FOUNDRY_MODEL              e.g. gpt-4.1

Notes:
  * A2APreviewTool (a2a_preview / protocol 0.3) is what Foundry-hosted prompt agents
    accept for a Foundry-agent target today. A2ATool (GA, 1.0) also works once the
    target's card resolves.
  * Never set agent_card_path for a Foundry-agent target - Foundry resolves its own.
"""

import os

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import A2APreviewTool, PromptAgentDefinition
from azure.identity import DefaultAzureCredential

ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"].rstrip("/")
MODEL = os.environ.get("FOUNDRY_MODEL", "gpt-4.1")
ORCHESTRATOR = os.environ.get("ORCHESTRATOR_NAME", "invoice-orchestrator")
CONNECTIONS = [
    "conn-invoice-extractor",
    "conn-invoice-validator",
    "conn-invoice-approver",
]

INSTRUCTIONS = (
    "You are the invoice orchestrator. Three connected specialist agents are available to you as "
    "A2A tools: an extractor (returns invoice JSON), a validator (checks math and PO compliance) "
    "and an approver (issues APPROVE / HOLD / REJECT). For any invoice, call the extractor, then "
    "the validator with its output, then the approver with the validator findings. Finish with a "
    "short summary of the decision and the key reason."
)


def main() -> None:
    project = AIProjectClient(endpoint=ENDPOINT, credential=DefaultAzureCredential())

    tools = []
    for name in CONNECTIONS:
        connection = project.connections.get(name)
        tool = A2APreviewTool()
        tool["project_connection_id"] = connection.id
        tools.append(tool)
        print(f"attached {name}")

    version = project.agents.create_version(
        agent_name=ORCHESTRATOR,
        definition=PromptAgentDefinition(model=MODEL, instructions=INSTRUCTIONS, tools=tools),
    )
    print(f"{ORCHESTRATOR} -> version {version.version}")
    print("Pin this version on the Activity Protocol endpoint before publishing to Teams.")


if __name__ == "__main__":
    main()
