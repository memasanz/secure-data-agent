"""Set up the Microsoft Fabric data agent tool for a Foundry agent, end-to-end,
following https://learn.microsoft.com/azure/foundry/agents/how-to/tools/fabric (python).

Steps:
  1. Create the project connection via the Azure Resource Manager REST API,
     passing BOTH workspace_id and artifact_id (doc-exact CustomKeys body).
  2. Verify the stored keys via listSecrets.
  3. Create a prompt agent (gpt-5.1) with MicrosoftFabricPreviewTool bound to the connection.
  4. Ask a question through the Responses API (identity passthrough / OBO).

Env (all optional except where noted):
  SUBSCRIPTION_ID   default 7ee2b43a-eaea-4259-be7b-c8c220bfbcf9
  RESOURCE_GROUP    default rg-fabric-foundry-eus2
  FOUNDRY_ACCOUNT   default ffndryfsnn
  FOUNDRY_PROJECT   default fabricagentfsnn
  PROJECT_ENDPOINT  default https://<account>.services.ai.azure.com/api/projects/<project>
  CONNECTION_NAME   default fabric-retailsales
  WORKSPACE_ID      Fabric workspace GUID (required)
  ARTIFACT_ID       Fabric data agent GUID (required)
  MODEL             model deployment name (default gpt-5.1)
  AGENT_NAME        default retail-insights
  QUESTION          default sample question
  INCLUDE_TARGET    default "1" (set target=api.fabric so the service recognizes it as AzureFabric)
  INCLUDE_METADATA  default "1" (also mirror ids into connection metadata)
"""
import os
import sys
import json

import requests
from azure.identity import AzureCliCredential

SUB = os.environ.get("SUBSCRIPTION_ID", "7ee2b43a-eaea-4259-be7b-c8c220bfbcf9")
RG = os.environ.get("RESOURCE_GROUP", "rg-fabric-foundry-eus2")
ACCOUNT = os.environ.get("FOUNDRY_ACCOUNT", "ffndryfsnn")
PROJECT = os.environ.get("FOUNDRY_PROJECT", "fabricagentfsnn")
ENDPOINT = os.environ.get(
    "PROJECT_ENDPOINT", f"https://{ACCOUNT}.services.ai.azure.com/api/projects/{PROJECT}"
)
CONN_NAME = os.environ.get("CONNECTION_NAME", "fabric-retailsales")
WS = os.environ.get("WORKSPACE_ID")
AID = os.environ.get("ARTIFACT_ID")
MODEL = os.environ.get("MODEL", "gpt-5.1")
AGENT_NAME = os.environ.get("AGENT_NAME", "retail-insights")
QUESTION = os.environ.get("QUESTION", "How many rows are in the sales table?")
INCLUDE_TARGET = os.environ.get("INCLUDE_TARGET", "1") == "1"
INCLUDE_METADATA = os.environ.get("INCLUDE_METADATA", "1") == "1"

API_VERSION = "2025-04-01-preview"

if not WS or not AID:
    sys.exit("Set WORKSPACE_ID and ARTIFACT_ID (both GUIDs from the data agent URL).")

cred = AzureCliCredential()


def arm_token():
    return cred.get_token("https://management.azure.com/.default").token


def conn_base():
    return (
        f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}"
        f"/providers/Microsoft.CognitiveServices/accounts/{ACCOUNT}/projects/{PROJECT}"
        f"/connections/{CONN_NAME}"
    )


def create_connection():
    # IMPORTANT: the service reads HYPHENATED key names (workspace-id / artifact-id).
    # The public doc shows underscores (workspace_id/artifact_id) but that is incorrect —
    # a portal-created connection stores them hyphenated, and only those are read at runtime.
    props = {
        "category": "CustomKeys",
        "authType": "CustomKeys",
        "target": "-",
        "metadata": {"type": "fabric_dataagent_preview"},
        "credentials": {"keys": {"workspace-id": WS, "artifact-id": AID}},
    }

    url = f"{conn_base()}?api-version={API_VERSION}"
    headers = {"Authorization": f"Bearer {arm_token()}", "Content-Type": "application/json"}
    r = requests.put(url, headers=headers, data=json.dumps({"properties": props}))
    r.raise_for_status()
    conn_id = r.json()["id"]
    print(f"[1] Connection created: {conn_id}")
    return conn_id


def verify_secrets():
    url = f"{conn_base()}/listsecrets?api-version={API_VERSION}"
    headers = {"Authorization": f"Bearer {arm_token()}", "Content-Type": "application/json"}
    r = requests.post(url, headers=headers)
    r.raise_for_status()
    keys = r.json().get("properties", {}).get("credentials", {}).get("keys", {})
    print(f"[2] Stored keys: workspace-id={keys.get('workspace-id')} artifact-id={keys.get('artifact-id')}")
    assert keys.get("workspace-id") == WS and keys.get("artifact-id") == AID, "keys mismatch!"


def build_and_query(conn_id):
    from azure.ai.projects import AIProjectClient
    from azure.ai.projects.models import (
        PromptAgentDefinition,
        MicrosoftFabricPreviewTool,
        FabricDataAgentToolParameters,
        ToolProjectConnection,
    )

    project = AIProjectClient(endpoint=ENDPOINT, credential=cred)
    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=MODEL,
            instructions=(
                "You are a retail analytics assistant. For any question about customers, "
                "products, sales, or revenue, use the Microsoft Fabric data agent tool."
            ),
            tools=[
                MicrosoftFabricPreviewTool(
                    fabric_dataagent_preview=FabricDataAgentToolParameters(
                        project_connections=[ToolProjectConnection(project_connection_id=conn_id)]
                    )
                )
            ],
        ),
    )
    print(f"[3] Agent: {agent.name} v{agent.version}")

    openai = project.get_openai_client(agent_name=agent.name)
    print(f"[4] Asking: {QUESTION}")
    resp = openai.responses.create(tool_choice="required", input=QUESTION)
    print("----- RESPONSE -----")
    print(resp.output_text)


def main():
    conn_id = create_connection()
    verify_secrets()
    build_and_query(conn_id)


if __name__ == "__main__":
    main()
