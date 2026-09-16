"""Query an existing Foundry prompt agent (reuses the latest version).

Env:
  FOUNDRY_PROJECT_ENDPOINT  project endpoint
  AGENT_NAME                agent name (default RetailInsightsAgent)
  QUESTION                  question to ask
"""
import os

from azure.identity import AzureCliCredential
from azure.ai.projects import AIProjectClient

ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
AGENT_NAME = os.environ.get("AGENT_NAME", "RetailInsightsAgent")
QUESTION = os.environ.get(
    "QUESTION",
    "How many rows are in the sales table, and what is total revenue by product category?",
)


def main():
    project = AIProjectClient(endpoint=ENDPOINT, credential=AzureCliCredential())
    openai = project.get_openai_client(agent_name=AGENT_NAME)
    print(f"Asking {AGENT_NAME}: {QUESTION}\n")
    response = openai.responses.create(tool_choice="required", input=QUESTION)
    print("----- RESPONSE -----")
    print(response.output_text)


if __name__ == "__main__":
    main()
