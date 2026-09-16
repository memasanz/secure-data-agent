"""Load the generated CSVs into the Fabric Lakehouse as Delta tables.

Writes directly to OneLake `Tables/` via delta-rs (no Spark). Auth uses an AAD
bearer token for the storage audience (passed in env var ONELAKE_TOKEN).

Env:
  ONELAKE_TOKEN   AAD access token for https://storage.azure.com
  WORKSPACE_ID    Fabric workspace GUID
  LAKEHOUSE_ID    Lakehouse GUID
"""
import os
import pandas as pd
from deltalake import write_deltalake

WS = os.environ["WORKSPACE_ID"]
LH = os.environ["LAKEHOUSE_ID"]
TOKEN = os.environ["ONELAKE_TOKEN"]
OUT = os.path.join(os.path.dirname(__file__), "out")

storage_options = {"bearer_token": TOKEN, "use_fabric_endpoint": "true"}

def table_uri(name):
    return f"abfss://{WS}@onelake.dfs.fabric.microsoft.com/{LH}/Tables/{name}"

def load(csv_name, table_name, date_cols=()):
    df = pd.read_csv(os.path.join(OUT, csv_name))
    for c in date_cols:
        df[c] = pd.to_datetime(df[c])
    write_deltalake(table_uri(table_name), df, mode="overwrite",
                    storage_options=storage_options)
    print(f"loaded {len(df):>6} rows -> Tables/{table_name}")

load("customers.csv", "customers", date_cols=["signup_date"])
load("products.csv", "products")
load("sales.csv", "sales", date_cols=["order_date"])
print("done.")
