"""Test Foundry -> Fabric data agent over the workspace-level private link.

Uses the FabricIQ preview MCP tool with a RemoteTool connection whose target is
the workspace-specific private FQDN and whose audience is the Power BI API.
Docs: https://learn.microsoft.com/azure/foundry/agents/how-to/tools/fabric-iq
"""
import os
import sys

from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition, FabricIQPreviewTool

ENDPOINT = os.environ.get(
    "PROJECT_ENDPOINT",
    "https://ffndryfsnn.services.ai.azure.com/api/projects/fabricagentfsnn",
)
MODEL = os.environ.get("MODEL_DEPLOYMENT_NAME", "gpt-4o")
CONN_NAME = os.environ.get("FABRIC_CONNECTION_NAME", "fabriciq-dataagent-vnet")
QUESTION = os.environ.get("QUESTION", "How many rows are in the sales table?")


def main() -> int:
    cred = DefaultAzureCredential()
    with AIProjectClient(endpoint=ENDPOINT, credential=cred) as project_client:
        conn = project_client.connections.get(CONN_NAME)
        print(f"Using connection: {conn.name}  id={conn.id}")

        tool = FabricIQPreviewTool(
            project_connection_id=conn.id,
            require_approval="never",
        )

        with project_client.get_openai_client() as openai_client:
            agent = project_client.agents.create_version(
                agent_name="fabriciq-vnet-test",
                definition=PromptAgentDefinition(
                    model=MODEL,
                    instructions=(
                        "You answer questions about retail sales data using the "
                        "Fabric IQ data agent tool. Always call the tool."
                    ),
                    tools=[tool],
                ),
            )
            print(f"Agent version created: {agent.name} v{agent.version}")
            try:
                resp = openai_client.responses.create(
                    input=QUESTION,
                    extra_body={
                        "agent_reference": {
                            "name": agent.name,
                            "type": "agent_reference",
                        }
                    },
                )
                print("=== RESPONSE ===")
                print(resp.output_text)
            finally:
                project_client.agents.delete_version(
                    agent_name=agent.name, agent_version=agent.version
                )
                print("Agent version deleted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
