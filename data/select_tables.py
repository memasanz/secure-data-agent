"""Select all tables on the data agent's lakehouse datasource, then republish.

Walks the element tree (Schemas -> schema -> tables), selects each leaf table,
and publishes the staging configuration so the agent can query the data.
"""
import os
from azure.identity import AzureCliCredential
from fabric.analytics.environment.credentials import (
    SetFabricAnalyticsDefaultTokenCredentialsGlobally,
)
from fabric.dataagent.client import FabricDataAgentManagement

WS = os.environ["WORKSPACE_ID"]
AID = os.environ["DATA_AGENT_ID"]

SetFabricAnalyticsDefaultTokenCredentialsGlobally(AzureCliCredential())
agent = FabricDataAgentManagement(AID, WS)
ds = agent.list_datasources()[0]

selected = []

def walk(root_id=None, depth=0):
    res = ds.get_elements(stage="staging", root_id=root_id)
    for el in res.get("value", []):
        name = el.get("displayName")
        eid = el.get("id")
        has_sub = el.get("hasSubElements")
        print("  " * depth + f"- {name} (type={el.get('type')}, selected={el.get('isSelected')}, hasSub={has_sub})")
        if has_sub:
            walk(eid, depth + 1)
        else:
            # leaf = table -> select it
            ds.update_element(eid, is_selected=True)
            selected.append(name)
            print("  " * depth + f"  -> selected '{name}'")

walk()
print("Selected tables:", selected)

agent.publish_staging(description="Select retail tables")
print("Republished.")
