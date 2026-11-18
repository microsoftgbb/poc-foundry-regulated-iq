"""Retire test credentials from the canceled custom-bot implementation.

The prepare, configure and deploy-application actions have been removed.
They must not recreate the rejected hosting architecture. Native Foundry
publishing uses the numbered reference scripts, but those scripts alone do
not implement the tax-officer authorization and retrieval boundary.
"""
import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / ".azure/commercial-state.json"
GRAPH = "https://graph.microsoft.com/v1.0"


def graph_patch(path: str, body: dict) -> None:
    result = subprocess.run(
        [
            "az", "rest", "--method", "PATCH", "--url", f"{GRAPH}/{path}",
            "--body", "@-", "--only-show-errors", "-o", "none",
        ],
        input=json.dumps(body), capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"Test credential retirement failed: {result.stderr[:1200]}")


def retire_tests() -> None:
    state = json.loads(STATE.read_text())
    for principal in state["principals"].values():
        graph_patch(
            f"applications/{principal['applicationObjectId']}",
            {"keyCredentials": []},
        )
        graph_patch(
            f"servicePrincipals/{principal['objectId']}",
            {"accountEnabled": False},
        )
    state["testCredentialsRetired"] = datetime.now(timezone.utc).isoformat()
    STATE.write_text(json.dumps(state, indent=2))
    print("Retired test certificates and disabled the three dedicated synthetic test principals.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["retire-tests"])
    parser.parse_args()
    retire_tests()
