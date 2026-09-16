"""Phase 4: build a Foundry prompt agent that answers questions using the
Microsoft Fabric data agent (RetailSalesAgent) via identity passthrough.

The agent orchestrates with the deployed gpt-5.1 model and calls the Fabric
data agent through a project connection (workspace_id + artifact_id). Fabric
runs queries under the signed-in user's identity (On-Behalf-Of), so the bare
MCP-token limitation does not apply here.

Env:
  FOUNDRY_PROJECT_ENDPOINT  e.g. https://ffndryfsnn.services.ai.azure.com/api/projects/fabricagentfsnn
  FOUNDRY_MODEL             model deployment name (default gpt-5.1)
  FABRIC_CONNECTION_NAME    project connection name (default fabric-retailsales)
  AGENT_NAME                agent name (default RetailInsightsAgent)
  QUESTION                  question to ask (default sample)
  KEEP                      if set, do not delete the agent version afterwards
"""
import os

from azure.identity import AzureCliCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    PromptAgentDefinition,
    MicrosoftFabricPreviewTool,
    FabricDataAgentToolParameters,
    ToolProjectConnection,
)

ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
MODEL = os.environ.get("FOUNDRY_MODEL", "gpt-5.1")
CONN_NAME = os.environ.get("FABRIC_CONNECTION_NAME", "fabric-retailsales")
AGENT_NAME = os.environ.get("AGENT_NAME", "RetailInsightsAgent")
QUESTION = os.environ.get(
    "QUESTION",
    "How many rows are in the sales table, and what is total revenue by product category?",
)
KEEP = bool(os.environ.get("KEEP"))

INSTRUCTIONS = (
    "You are a retail analytics assistant. For any question about customers, "
    "products, sales, revenue, or orders, use the Microsoft Fabric data agent "
    "tool to query the RetailSales lakehouse. Base answers only on data the "
    "Fabric tool returns and show the numbers clearly."
)


def main():
    cred = AzureCliCredential()
    project = AIProjectClient(endpoint=ENDPOINT, credential=cred)

    conn = project.connections.get(CONN_NAME)
    print(f"Fabric connection: {conn.id}")

    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=MODEL,
            instructions=INSTRUCTIONS,
            tools=[
                MicrosoftFabricPreviewTool(
                    fabric_dataagent_preview=FabricDataAgentToolParameters(
                        project_connections=[
                            ToolProjectConnection(project_connection_id=conn.id)
                        ]
                    )
                )
            ],
        ),
    )
    print(f"Agent created: id={agent.id} name={agent.name} version={agent.version}")

    openai = project.get_openai_client(agent_name=agent.name)
    print(f"\nAsking: {QUESTION}\n")
    response = openai.responses.create(tool_choice="required", input=QUESTION)
    print("----- RESPONSE -----")
    print(response.output_text)

    if not KEEP:
        project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)
        print("\nAgent version deleted (set KEEP=1 to persist).")
    else:
        print(f"\nAgent kept: {agent.name} v{agent.version}")


if __name__ == "__main__":
    main()
