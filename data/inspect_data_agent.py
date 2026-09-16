"""Inspect the Fabric data agent's datasources and selected tables."""
import os
from azure.identity import AzureCliCredential
from fabric.analytics.environment.credentials import (
    SetFabricAnalyticsDefaultTokenCredentialsGlobally,
)
from fabric.dataagent.client import FabricDataAgentManagement

WS = os.environ["WORKSPACE_ID"]
AID = os.environ["DATA_AGENT_ID"]

cred = AzureCliCredential()
SetFabricAnalyticsDefaultTokenCredentialsGlobally(cred)

agent = FabricDataAgentManagement(AID, WS)
print("agent methods:", [m for m in dir(agent) if not m.startswith("_")])

for getter in ("get_staging_datasources", "list_datasources", "get_published_datasources"):
    if hasattr(agent, getter):
        try:
            dss = getattr(agent, getter)()
            print(f"\n== {getter}: {len(dss)} datasource(s) ==")
            for ds in dss:
                print("  ds methods:", [m for m in dir(ds) if not m.startswith("_")])
                for attr in ("id", "display_name", "type", "workspace_id"):
                    print(f"   {attr}:", getattr(ds, attr, None))
                for tg in ("get_tables", "list_tables", "get_selected_tables"):
                    if hasattr(ds, tg):
                        try:
                            print(f"   {tg}():", getattr(ds, tg)())
                        except Exception as e:  # noqa: BLE001
                            print(f"   {tg}() error: {e}")
        except Exception as e:  # noqa: BLE001
            print(f"{getter} error: {e}")
