# Secure Data Agent — Private Microsoft Fabric + Azure AI Foundry

Reference architecture and Infrastructure-as-Code for running **Microsoft Fabric** with
**workspace-level private link** (public access disabled) connected to an **Azure AI Foundry
data agent** over a **fully private network** — designed for **sensitive-data** workloads where
no traffic may traverse the public internet.

---

## Why this exists

Three private-network concerns are easy to conflate. This project keeps them separate and solves
all three:

| # | Concern | Mechanism |
|---|---------|-----------|
| 1 | How users/admins reach the locked-down **Fabric** workspace | Fabric **workspace-level private endpoint** + **P2S VPN** into the VNet |
| 2 | How users/apps reach the locked-down **Foundry** project | Foundry **private endpoint** + the same **P2S VPN** |
| 3 | How the **Foundry agent queries the Fabric data agent** | Foundry agent runtime (**VNet-injected**) egresses to the Fabric workspace private endpoint over the **workspace-level private link**, using a **RemoteTool** connection with **Entra OBO** (identity passthrough) |

The key insight for concern **3**: once the Fabric workspace blocks public access, the shared
`api.fabric.microsoft.com` host no longer works. The Foundry agent must target the
**workspace-specific private FQDN** through a dedicated connection (see
[How Foundry talks to Fabric](#how-foundry-talks-to-fabric)).

Because the workload is a **Foundry Agent Service (data agent)** with private networking, the
**Standard Setup** applies, which **requires Bring-Your-Own** Storage, AI Search, and Cosmos DB
(shared/Microsoft-managed resources cannot be used privately).

---

## Architecture

```
 Dev machine (Azure VPN client, Entra ID)
      │  P2S VPN  (client DNS ─▶ Azure DNS Private Resolver ─▶ privatelink.* zones)
      ▼
 ┌───────────────────────── VNet 192.168.0.0/16 (eastus2) ──────────────────────────┐
 │  GatewaySubnet ──── VPN Gateway (P2S / OpenVPN / Entra auth)                       │
 │  snet-dnsresolver ─ Azure DNS Private Resolver (inbound endpoint)                  │
 │                                                                                   │
 │  snet-pe ── Private Endpoints:                                                    │
 │      • Fabric workspace ──▶ Microsoft Fabric workspace (public access DISABLED)   │
 │      • Foundry account  ──▶ Azure AI Foundry project    (public access DISABLED)  │
 │      • Storage / Search / Cosmos / Key Vault  (BYO dependencies)                  │
 │                                                                                   │
 │  snet-agents (/27, delegated Microsoft.App/environments)                          │
 │      └─ VNet-injected ──▶ Azure AI Foundry — Agent Service                        │
 │                            backed by BYO Storage + AI Search + Cosmos DB          │
 └───────────────────────────────────────────────────────────────────────────────────┘

 Query data path (both services locked down):
   ① User → P2S VPN → Foundry project private endpoint → creates a run
   ② Foundry agent runtime (snet-agents) → Fabric workspace private endpoint
        via the workspace-specific FQDN, carrying the user's Entra token (OBO)
   ③ Fabric data agent answers over OneLake → response returns to the user
   No hop leaves the private network.
```

### How Foundry talks to Fabric

When the Fabric workspace blocks public access, the native Foundry Fabric tool (which calls the
shared `api.fabric.microsoft.com` host) fails. The supported path is the **Fabric IQ** tool with a
**RemoteTool** connection that targets the workspace-specific private endpoint and passes the
signed-in user's Entra token (On-Behalf-Of):

| Connection property | Value |
|---------------------|-------|
| `category` | `RemoteTool` |
| `authType` | `UserEntraToken` (identity passthrough / OBO) |
| `target` | `https://{workspaceId-nodashes}.z{xy}.w.api.fabric.microsoft.com/v1/mcp/workspaces/{workspaceId}/dataagents/{dataAgentId}/agent` |
| `audience` | `https://analysis.windows.net/powerbi/api` (Power BI resource; `DataAgent.Execute.All` scope) |

`{xy}` is the first two characters of the workspace ID. Reference the connection from the agent via
`FabricIQPreviewTool(project_connection_id=...)` (SDK `azure-ai-projects >= 2.2.0`). The Foundry
agent runtime is VNet-injected, so it resolves that FQDN to the private endpoint IP and routes
entirely over the workspace-level private link. See [`data/test_fabriciq_vnet.py`](data/test_fabriciq_vnet.py)
for a runnable end-to-end example, and the official
[Fabric IQ tool docs](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/fabric-iq#virtual-network-support).

> **Common failure:** a connection with the right target but the wrong `audience`
> (`https://api.fabric.microsoft.com`) authenticates but is rejected for data-agent execution — the
> run fails with a 424. Use the Power BI audience above.

Full design rationale, decisions, and open items:
**[`fabric-foundry-private-network-spec.md`](fabric-foundry-private-network-spec.md)**.

---

## Repository layout

```
.
├── README.md                                # this file
├── fabric-foundry-private-network-spec.md   # architecture spec
├── infra/
│   ├── README.md                            # detailed deploy runbook
│   ├── 01-network/                          # VNet + 4 subnets + NSGs             (authored)
│   ├── 02-access/                           # P2S VPN Gateway + DNS Resolver      (authored)
│   │   └── modules/
│   ├── 03-foundry/                          # Foundry + BYO + private endpoints   (upstream sample)
│   │   ├── get-foundry-sample.ps1
│   │   └── foundry.parameters.example.json
│   └── 04-fabric/                           # Fabric capacity, workspace, private link, deny-public
│       ├── capacity.bicep                   #   Fabric capacity (F-SKU)
│       ├── create-workspace.ps1             #   create workspace + assign capacity
│       ├── main.bicep                       #   workspace private-link resource + PE + DNS zone
│       ├── set-deny-public-access.ps1       #   toggle workspace inbound public access (Deny/Allow)
│       └── set-hosts-overrides.ps1          #   optional local hosts entries for private FQDNs
└── data/                                    # sample-data + agent wiring (Python)
    ├── generate_retail_sales.py             #   synthetic retail dataset
    ├── load_to_lakehouse.py                 #   load CSVs into the lakehouse
    ├── create_data_agent.py                 #   create/publish the Fabric data agent
    ├── setup_fabric_connection.py           #   create the Foundry connection + agent
    └── test_fabriciq_vnet.py                #   end-to-end Foundry→Fabric test over private link
```

Stage 03 reuses the upstream **microsoft-foundry/foundry-samples**
`15-private-network-standard-agent-setup` template rather than re-implementing its fragile
capability-host logic. Stages 01/02 add the VNet and inbound access the sample omits; stage 04 adds
the Fabric capacity, workspace, and workspace-level private link.

---

## Prerequisites

- **Azure CLI** 2.80+ and **Bicep** 0.43+ (`az bicep version`)
- **git**
- Azure subscription with rights to create resources **and assign RBAC** (Owner or equivalent)
- Required resource providers registered (see the spec): `Microsoft.CognitiveServices`,
  `Microsoft.Search`, `Microsoft.DocumentDB`, `Microsoft.Storage`, `Microsoft.KeyVault`,
  `Microsoft.App`, `Microsoft.Network`, `Microsoft.MachineLearningServices`, `Microsoft.ContainerService`

---

## Quick start

```powershell
$RG  = 'rg-fabric-foundry-eus2'
$LOC = 'eastus2'
az group create -n $RG -l $LOC

# Stage 01 — network
az deployment group create -g $RG -n stage01-network `
  -f infra/01-network/main.bicep -p infra/01-network/main.bicepparam

# Stage 02 — access (DNS resolver is fast; VPN gateway ~30-45 min)
$vnetId = az deployment group show -g $RG -n stage01-network --query properties.outputs.vnetId.value -o tsv
# ...see infra/README.md for the full stage 02 + stage 03 sequence

# Stage 04 — Fabric workspace-level private link, then lock down public access
az deployment group create -g $RG -n stage04-fabric `
  -f infra/04-fabric/main.bicep -p infra/04-fabric/main.bicepparam
./infra/04-fabric/set-deny-public-access.ps1 -Action Deny   # -Action Allow to revert
```

The complete, copy-pasteable runbook (capturing outputs, setting VNet DNS to the resolver IP,
fetching + deploying the Foundry sample, deploying the Fabric workspace + private link, connecting
the VPN, and wiring the data agent) is in **[`infra/README.md`](infra/README.md)**.

---

## Key facts & gotchas

- **Region:** `eastus2` (all resources co-located; Fabric capacity region must match).
- **BYO is mandatory** for the private data-agent setup: your own Storage + AI Search + Cosmos DB.
- **Agent subnet must be 172.x/192.x** — the platform rejects 10.x — hence the `192.168.0.0/16` VNet.
- **P2S clients can't use Azure DNS (168.63.129.16)** directly; the **DNS Private Resolver** provides
  `privatelink.*` resolution over the VPN. Set the VNet DNS to the resolver's inbound IP.
- **Cosmos DB** needs **≥ 3000 RU/s** (5 containers × 1000) for the Standard agent setup.
- **VPN gateway provisioning is slow** (~30-45 min).
- **Foundry→Fabric under lockdown uses the workspace-specific private FQDN**, not the shared
  `api.fabric.microsoft.com` host, with `audience = https://analysis.windows.net/powerbi/api`
  (see [How Foundry talks to Fabric](#how-foundry-talks-to-fabric)).
- **Lock down at the workspace level, not the tenant level.** The tenant-level Fabric private-link
  toggle isolates *every* workspace in the tenant; this project uses per-workspace deny-public
  (`set-deny-public-access.ps1`) so only the target workspace is affected.
- The **Fabric data agent must be (re)published** before external callers can run it — a stale
  published stage makes every external run fail while the interactive draft still works.

---

## Deployment status (this environment)

- ✅ Stage 01 (network) — VNet + subnets + NSGs
- ✅ Stage 02 (access) — P2S VPN Gateway (`vpngw-fabric-foundry`) + DNS Private Resolver
- ✅ Stage 03 (Foundry) — Foundry project + BYO Storage/Search/Cosmos + private endpoints (public access disabled)
- ✅ Stage 04 (Fabric) — capacity + workspace + workspace-level private link + **deny-public applied**
- ✅ Data agent published; Foundry↔Fabric verified end-to-end over the private link (both locked down)
