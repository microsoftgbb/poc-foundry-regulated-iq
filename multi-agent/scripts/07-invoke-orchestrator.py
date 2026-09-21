"""
Invoke the orchestrator and watch it delegate to the three sub-agents over A2A.

Run from inside the VNet when public network access is disabled.
  pip install "azure-ai-projects>=2.5.0" azure-identity openai
"""

import os

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"].rstrip("/")
ORCHESTRATOR = os.environ.get("ORCHESTRATOR_NAME", "invoice-orchestrator")

SAMPLE_INVOICE = (
    "Process this invoice: Contoso Office Supplies, INV-4471, PO PO-88213. "
    "10 Ergonomic chair @220=2200; 4 Standing desk @610=2440; 25 Notebook @12=300. "
    "Subtotal 4940, Tax 419.90, Shipping 75, Total 5434.90. "
    "Standing desks were NOT on PO-88213."
)


def main() -> None:
    project = AIProjectClient(endpoint=ENDPOINT, credential=DefaultAzureCredential())
    openai = project.get_openai_client()

    response = openai.responses.create(
        input=SAMPLE_INVOICE,
        extra_body={"agent_reference": {"name": ORCHESTRATOR, "type": "agent_reference"}},
    )
    print(response.output_text)


if __name__ == "__main__":
    main()
