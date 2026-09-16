"""Validate the published Fabric data agent through its MCP endpoint.

Speaks MCP over streamable HTTP with a Fabric bearer token, discovers the
single tool, sends a question, and prints the answer.

Env:
  WORKSPACE_ID    Fabric workspace GUID
  DATA_AGENT_ID   Published data agent GUID
  QUESTION        (optional) question to ask
"""
import asyncio
import json
import os

from azure.identity import AzureCliCredential
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

WS = os.environ["WORKSPACE_ID"]
AID = os.environ["DATA_AGENT_ID"]
QUESTION = os.environ.get("QUESTION", "What is total revenue by product category?")
URL = f"https://api.fabric.microsoft.com/v1/mcp/workspaces/{WS}/dataagents/{AID}/agent"


def _text(result):
    parts = []
    for c in getattr(result, "content", []) or []:
        t = getattr(c, "text", None)
        if t:
            parts.append(t)
    return "\n".join(parts) if parts else str(result)


async def main():
    token = AzureCliCredential().get_token("https://api.fabric.microsoft.com/.default").token
    headers = {"Authorization": f"Bearer {token}"}

    async with streamablehttp_client(URL, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = (await session.list_tools()).tools
            print("Tools:", [t.name for t in tools])
            tool = tools[0]
            schema = tool.inputSchema or {}
            props = list((schema.get("properties") or {}).keys())
            print(f"Tool '{tool.name}' args: {props}")

            # pick the string arg that takes the question
            arg = None
            for cand in ("question", "query", "input", "prompt", "message"):
                if cand in props:
                    arg = cand
                    break
            if arg is None and props:
                arg = props[0]
            args = {arg: QUESTION} if arg else {}
            print(f"Asking: {QUESTION!r} (arg={arg})")

            result = await session.call_tool(tool.name, args)
            print("----- ANSWER -----")
            print(_text(result))


if __name__ == "__main__":
    asyncio.run(main())
