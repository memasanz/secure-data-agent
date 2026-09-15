# Secure Data Agent — Private Microsoft Fabric + Azure AI Foundry

Reference architecture and Infrastructure-as-Code for running **Microsoft Fabric** with
**workspace-level private link** (public access disabled) connected to an **Azure AI Foundry
data agent** over a **fully private network** — designed for **sensitive-data** workloads where
no traffic may traverse the public internet.

---

## Why this exists

Two independent private-link concerns are easy to conflate. This project keeps them separate and
solves both:

| Direction | Concern | Mechanism |
|-----------|---------|-----------|
| **Inbound** | How users/admins reach the locked-down Fabric workspace | VNet **private endpoint** + **P2S VPN** into the VNet |
| **Outbound** | How Fabric reaches the Foundry data agent | Fabric **managed private endpoint** to a private Foundry |

Because the workload is a **Foundry Agent Service (data agent)** with private networking, the
**Standard Setup** applies, which **requires Bring-Your-Own** Storage, AI Search, and Cosmos DB
(shared/Microsoft-managed resources cannot be used privately).

---

## Architecture

```
 Dev machine (Azure VPN client, Entra ID)
      │  P2S VPN  (client DNS ─▶ DNS Private Resolver)
      ▼
 ┌───────────────────────── VNet 192.168.0.0/16 (eastus2) ─────────────────────────┐
 │  GatewaySubnet ── VPN Gateway (P2S)                                              │
 │  snet-dnsresolver ── Azure DNS Private Resolver (inbound)                        │
 │                                                                                  │
 │  snet-pe ── Private Endpoints:                                                   │
 │      • Fabric ──────────▶ Microsoft Fabric workspace (public access DISABLED)    │
 │      • Foundry            │                                                       │
 │      • Storage / Search   │  Fabric managed private endpoint (approved)          │
 │      • Cosmos / Key Vault ▼                                                       │
 │  snet-agents (/27, delegated Microsoft.App/environments)                         │
 │      └─ VNet injection ─▶ Azure AI Foundry — Agent Service (public DISABLED)      │
 │                             backed by BYO Storage + AI Search + Cosmos DB         │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

Full design rationale, decisions, and open items:
**[`fabric-foundry-private-network-spec.md`](fabric-foundry-private-network-spec.md)**.

---

## Repository layout

```
.
├── README.md                                # this file
├── fabric-foundry-private-network-spec.md   # architecture spec
└── infra/
    ├── README.md                            # detailed deploy runbook
    ├── 01-network/                          # VNet + 4 subnets + NSGs           (authored)
    ├── 02-access/                           # P2S VPN Gateway + DNS Resolver    (authored)
    │   └── modules/
    └── 03-foundry/                          # Foundry + BYO + private endpoints (upstream sample)
        ├── get-foundry-sample.ps1
        └── foundry.parameters.example.json
```

Stage 03 reuses the upstream **microsoft-foundry/foundry-samples**
`15-private-network-standard-agent-setup` template rather than re-implementing its fragile
capability-host logic. Stages 01/02 add the VNet and inbound access the sample omits.

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
```

The complete, copy-pasteable runbook (capturing outputs, setting VNet DNS to the resolver IP,
fetching + deploying the Foundry sample, connecting the VPN, and the **Fabric portal steps**) is in
**[`infra/README.md`](infra/README.md)**.

---

## Key facts & gotchas

- **Region:** `eastus2` (all resources co-located).
- **BYO is mandatory** for the private data-agent setup: your own Storage + AI Search + Cosmos DB.
- **Agent subnet must be 172.x/192.x** — the platform rejects 10.x — hence the `192.168.0.0/16` VNet.
- **P2S clients can't use Azure DNS (168.63.129.16)** directly; the **DNS Private Resolver** provides
  `privatelink.*` resolution over the VPN. Set the VNet DNS to the resolver's inbound IP.
- **Cosmos DB** needs **≥ 3000 RU/s** (5 containers × 1000) for the Standard agent setup.
- **VPN gateway provisioning is slow** (~30-45 min).
- **Fabric private link and the Fabric→Foundry managed private endpoint are configured in the Fabric
  portal**, not via ARM/Bicep.

---

## Deployment status (this environment)

- ✅ Stage 01 (network) deployed to `rg-fabric-foundry-eus2` (eastus2)
- ⬜ Stage 02 (VPN + DNS resolver)
- ⬜ Stage 03 (Foundry + BYO)
- ⬜ Fabric portal configuration
