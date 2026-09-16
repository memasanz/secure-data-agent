"""Phase 3 — create, configure, and publish a Fabric data agent over the RetailSales Lakehouse.

Uses fabric-data-agent-sdk against the public Fabric REST API (works outside a
Fabric notebook via AzureCliCredential).

Env:
  WORKSPACE_ID   Fabric workspace GUID
  LAKEHOUSE_ID   Lakehouse (data source) GUID
  AGENT_NAME     (optional) data agent display name
"""
import os

from azure.identity import AzureCliCredential
from fabric.analytics.environment.credentials import (
    SetFabricAnalyticsDefaultTokenCredentialsGlobally,
)
from fabric.dataagent.client import create_data_agent

WS = os.environ["WORKSPACE_ID"]
LH = os.environ["LAKEHOUSE_ID"]
AGENT_NAME = os.environ.get("AGENT_NAME", "RetailSalesAgent")

INSTRUCTIONS = (
    "You are a retail sales analytics assistant. Answer questions about retail "
    "sales using the RetailSales lakehouse, which has three Delta tables: "
    "`sales` (order_id, order_date, customer_id, product_id, quantity, unit_price, "
    "discount, total_amount, channel), `customers` (customer_id, customer_name, "
    "region, segment, signup_date), and `products` (product_id, product_name, "
    "category, unit_price). Join sales to customers on customer_id and to products "
    "on product_id. Revenue = total_amount. Prefer concise, numeric answers and "
    "state any assumptions."
)

DS_INSTRUCTIONS = (
    "Use the `sales` fact table for revenue/quantity metrics. Dimensions: "
    "`customers` (region, segment) and `products` (category, product_name). "
    "order_date and signup_date are dates; total_amount is net revenue after discount."
)

EXAMPLE_QUERIES = [
    "What is total revenue by product category?",
    "Which region has the highest total sales?",
    "Show the top 5 customers by total_amount.",
    "What is the average discount by sales channel?",
]


def main():
    cred = AzureCliCredential()
    SetFabricAnalyticsDefaultTokenCredentialsGlobally(cred)

    print(f"Creating data agent '{AGENT_NAME}' in workspace {WS} ...")
    agent = create_data_agent(data_agent_name=AGENT_NAME, workspace_id=WS)
    print("Created. agent attrs:", [a for a in dir(agent) if not a.startswith("_")])

    agent.update_settings(ai_instructions=INSTRUCTIONS)
    print("Set AI instructions.")

    agent.add_staging_datasource(artifact_name_or_id=LH, workspace_id_or_name=WS)
    print(f"Added lakehouse {LH} as data source.")

    # Best-effort: add data-source instructions + example queries (API names vary by version).
    try:
        ds = agent.get_datasources()[0] if hasattr(agent, "get_datasources") else None
        if ds is not None:
            if hasattr(ds, "update_configuration"):
                ds.update_configuration(instructions=DS_INSTRUCTIONS)
            for q in EXAMPLE_QUERIES:
                if hasattr(ds, "add_example_query"):
                    ds.add_example_query(q)
            print("Added data-source instructions + example queries.")
    except Exception as e:  # noqa: BLE001
        print(f"(non-fatal) could not add DS instructions/examples: {e}")

    agent.publish_staging(description="Initial publish - retail sales")
    print("Published.")

    # Try to surface the data agent (artifact) id for the MCP endpoint.
    aid = getattr(agent, "id", None) or getattr(agent, "artifact_id", None) \
        or getattr(agent, "data_agent_id", None)
    print(f"DATA_AGENT_ID={aid}")


if __name__ == "__main__":
    main()
