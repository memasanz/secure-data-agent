# Spec: Private Microsoft Fabric + Azure AI Foundry Network Architecture

**Status:** Implemented & verified
**Last updated:** 2026-09-16
**Owner:** _TBD_

---

## 1. Purpose

Define the network architecture to run **Microsoft Fabric** with **public access disabled**
(**workspace-level** private link) and connect it securely to **Azure AI Foundry** — specifically
the **Foundry Agent Service (data agent)** — for a workload handling **sensitive data**. All traffic
between services must stay on the Microsoft backbone / private endpoints and never traverse the
public internet.

### Decisions locked in
- **Region:** `eastus2` — all resources + VNet co-located.
- Fabric private link scope: **workspace-level**.
- Inbound access into the VNet: **VPN Gateway — Point-to-Site (P2S)** (no Bastion). Chosen to let a
  single dev machine connect for testing without on-prem hardware.
- The **Foundry agent must call the Fabric data agent** (the Fabric data agent is *consumed from*
  Foundry Agent Service, Standard + Private Networking). Under workspace-level private link this uses
  a Foundry **RemoteTool** connection to the workspace-specific private FQDN with Entra OBO — see §5.2.
- **BYO data resources: create NEW dedicated** Storage + AI Search + Cosmos DB (required — see §5.3).
- IaC: **Bicep**.
- **VNet:** new greenfield VNet, **`192.168.0.0/16`** (the Foundry agent injection subnet must be in
  the 172.x/192.x range; 10.x is rejected).
- **DNS:** new **Azure Private DNS zones**, plus an **Azure DNS Private Resolver** so the P2S client
  can resolve private FQDNs (see §5.6).

## 2. Scope

In scope:
- Fabric workspace inbound access lockdown (private link + public access disabled).
- Client/admin connectivity into the private network (**VPN Gateway**, P2S/S2S).
- **Foundry → Fabric** private connectivity: the Foundry agent querying the Fabric data agent over
  the workspace-level private link (RemoteTool connection, Entra OBO).
- Locking down Foundry and its dependent resources (Storage, Key Vault, AI Search, Cosmos DB).

Out of scope (for now):
- CI/CD pipelines, DNS integration with on-prem, and identity/RBAC design detail.
- Data ingestion sources beyond Foundry dependencies.

## 3. Key Concept: Three Private-Network Concerns

There are **three separate** connectivity concerns. Conflating them leads to over-building or to the
wrong mechanism.

| # | Concern | Mechanism | Needs customer VNet/VPN? |
|---|---------|-----------|--------------------------|
| 1 | **Inbound to Fabric** — how users/admins reach the locked-down workspace | Fabric **workspace-level private endpoint** in the customer VNet + a path in (P2S VPN) | ✅ Yes |
| 2 | **Inbound to Foundry** — how users/apps reach the locked-down project | Foundry **private endpoint** in the customer VNet + the same P2S VPN | ✅ Yes |
| 3 | **Foundry → Fabric** — how the Foundry agent queries the Fabric data agent | Foundry **RemoteTool** connection (Fabric IQ) to the **workspace-specific private FQDN** with **Entra OBO**; the VNet-injected agent egresses over the workspace-level private link | ✅ Yes (agent runs in `snet-agents`) |

> **Not the same as** a *Fabric → Foundry* managed private endpoint (Fabric calling Foundry, e.g. to
> use a Foundry-hosted model). That is the reverse direction and is **optional** — it is **not** what
> enables the data-agent query flow in concern 3. See §5.2.

## 4. Requirements

### 4.1 Functional
- FR1: Fabric workspace reachable only over private link; public internet access disabled.
- FR2: Authorized users/admins can reach the private Fabric endpoint from a controlled path.
- FR3: The Foundry agent can query the Fabric data agent privately (Foundry → Fabric over the
  workspace-level private link), using the signed-in user's identity (OBO).
- FR4: Foundry and its dependent data stores are reachable only via private endpoints.

### 4.2 Non-functional / Security
- NFR1: No sensitive-data traffic traverses the public internet.
- NFR2: Authentication uses Entra ID / managed identity in preference to keys.
- NFR3: Private DNS resolution configured for every private endpoint FQDN.
- NFR4: Design supports tightening from a "test" posture to "fully private" without rearchitecting.

## 5. Architecture

### 5.1 Inbound — Locking Down Fabric
- Enable **workspace-level private link** on Fabric.
- **Disable public internet access** for the workspace.
- Provision a **customer VNet** (greenfield, in `eastus2`) with a **private endpoint** to Fabric.
- Provide a path into the VNet using a **Point-to-Site (P2S) VPN Gateway**:
  - Each admin/dev machine runs the Azure VPN client and connects into the VNet.
  - No on-prem VPN device or Bastion required — ideal for a single tester.
- **DNS for the P2S client (critical):** a P2S-connected machine **cannot** use Azure DNS
  (`168.63.129.16`) directly, so it can't resolve `privatelink.*` names out of the box. Deploy an
  **Azure DNS Private Resolver** (inbound endpoint) in the VNet and set the **P2S VPN client DNS**
  to the resolver's inbound IP. The resolver forwards to the linked Private DNS zones.

> Validation: connect the P2S VPN, resolve the Fabric FQDN to its **private IP** (via the DNS
> resolver), then browse Fabric — traffic flows over the VPN into the VNet private endpoint.

### 5.2 Foundry → Fabric — querying the data agent (workspace-level private link)

The Foundry agent consumes the Fabric **data agent**. Once the Fabric workspace disables public
access, the native Foundry Fabric tool (which calls the shared `api.fabric.microsoft.com` host) stops
working — runs fail with **424**. The supported private path:

- Use the **Fabric IQ** tool with a **RemoteTool** connection whose `target` is the
  **workspace-specific private FQDN**
  (`https://{workspaceId-nodashes}.z{xy}.w.api.fabric.microsoft.com/v1/mcp/workspaces/{workspaceId}/dataagents/{dataAgentId}/agent`),
  `authType = UserEntraToken` (identity passthrough / OBO), and
  `audience = https://analysis.windows.net/powerbi/api` (Power BI resource; `DataAgent.Execute.All`).
- The Foundry agent runtime is **VNet-injected** (`snet-agents`), so it resolves that FQDN to the
  Fabric private-endpoint IP and reaches the workspace **entirely over the workspace-level private
  link** — no public hop.
- **Gotchas:** (a) a connection with the right target but `audience = https://api.fabric.microsoft.com`
  authenticates yet is rejected for data-agent execution (424 — use the Power BI audience);
  (b) the data agent must be **(re)published** before any external caller can run it — a stale
  published stage fails every external run while the interactive draft still works.

> Reference: [Fabric IQ tool — virtual network support](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/fabric-iq#virtual-network-support).
> Runnable example: `data/test_fabriciq_vnet.py`.

**Optional reverse leg — Fabric → Foundry (MPE):** only if *Fabric* must privately call the *Foundry*
resource (e.g. use a Foundry-hosted model from Fabric). Create a Fabric **managed private endpoint**
targeting Foundry and **approve** it on the Foundry side. This MPE lives in a Microsoft-managed VNet
(no customer VNet/VPN for that leg) and is **not** required for the query flow above.

### 5.3 Locking Down Foundry + Agent Service (Sensitive-Data Posture)

Because Fabric calls the **Foundry data agent**, the target is the **Foundry Agent Service** in its
**"Standard Setup with Private Networking"** mode. This mode is **required** for VNet isolation, and
Standard Setup **mandates Bring Your Own (BYO)** data resources — shared/Microsoft-managed resources
are **not** an option with private networking. **Decision: create new dedicated** BYO resources.

- Set Foundry **public network access = Disabled**.
- Add an **inbound private endpoint** on the Foundry resource (sub-resource target: `account`).
- **VNet injection:** provide a **subnet delegated to `Microsoft.App/environments`, sized `/27` or
  larger**. The platform injects agent compute into this subnet.
- **BYO (create new)** — required so all agent data stays in your tenant. Private setup does **not**
  auto-create these or their private endpoints:
  - **Azure Storage** (blob) — uploaded files
  - **Azure AI Search** — vector stores (in scope: RAG)
  - **Azure Cosmos DB** (NoSQL) — thread/conversation/agent state. **Requires ≥ 3000 RU/s** (Standard
    provisions 5 containers × 1000 RU/s; provisioned or serverless supported).
- Each BYO resource: set **public access = Disabled** and add its **own private endpoint** in the VNet.
- **Data-plane RBAC** — assigned by the Stage 03 sample to the Foundry **project** managed identity
  (verify with `infra/03-foundry/verify-agent-rbac.ps1`):
  - Cosmos DB → **Cosmos DB Operator** (ARM) + **Cosmos DB Built-in Data Contributor** (data-plane SQL role)
  - AI Search → **Search Index Data Contributor** + **Search Service Contributor**
  - Storage → **Storage Blob Data Contributor** (`azureml-blobstore`) / **Storage Blob Data Owner** (`agents-blobstore`)
- **AI Search region exception:** `eastus2` and `westus3` were **out of Search capacity** (standard/
  basic SKUs), so AI Search is created in **`westus2`** (`basic` SKU) via `03-foundry/search-byo.bicep`
  and its **private endpoint is built cross-region into `snet-pe` (eastus2)**. Search therefore lives
  in westus2 while its PE + DNS live in the eastus2 VNet — still fully private.
- Register required resource providers: `Microsoft.KeyVault`, `Microsoft.CognitiveServices`,
  `Microsoft.Storage`, `Microsoft.MachineLearningServices`, `Microsoft.Search`, `Microsoft.Network`,
  `Microsoft.App`, `Microsoft.ContainerService` (+ `Microsoft.Bing` if the Bing tool is used).

**Foundry → Fabric leg:** the Foundry agent reaches the (private) Fabric workspace via the RemoteTool
connection described in §5.2, over the workspace-level private link — not via a Fabric MPE.

### 5.4 Required subnets (single greenfield VNet, eastus2)

| Subnet | Purpose | Sizing / delegation |
|--------|---------|---------------------|
| `snet-pe` | Private endpoints (Fabric, Foundry, Storage, Search, Cosmos, Key Vault) | /24 suggested |
| `snet-agents` | Foundry Agent Service VNet injection | **/27 or larger**, delegated to `Microsoft.App/environments` |
| `snet-dnsresolver` | Azure DNS Private Resolver inbound endpoint | /28 min, delegated to `Microsoft.Network/dnsResolvers` |
| `GatewaySubnet` | VPN Gateway (P2S) — name is mandatory | /27 or larger |

### 5.5 Target End-State Summary

| Resource | How it's secured | How it's reached |
|----------|------------------|------------------|
| Fabric workspace | Workspace-level private link, public access disabled | Customer VNet private endpoint + **VPN** (inbound) |
| Azure AI Foundry (Agent Service) | Private endpoint + VNet injection, public access disabled | Users via VNet PE + **VPN**; agent egresses to Fabric over the workspace private link |
| Azure Storage (BYO) | Private endpoint, public disabled | Private endpoint in VNet |
| Azure AI Search (BYO) | Private endpoint, public disabled | Private endpoint in VNet |
| Azure Cosmos DB (BYO) | Private endpoint, public disabled | Private endpoint in VNet |
| Key Vault | Private endpoint, public disabled | Private endpoint in VNet |

### 5.6 Private DNS zones + resolver (create new, link to VNet)

Create these **Azure Private DNS zones** and link them to the VNet. Deploy an **Azure DNS Private
Resolver** (inbound endpoint in `snet-dnsresolver`) and set the **P2S VPN client DNS** to the
resolver's inbound IP so your machine resolves the `privatelink.*` names over the VPN. (Direct use of
`168.63.129.16` does not work from P2S clients — the resolver is what makes name resolution work.)

| Resource | Sub-resource | Private DNS zone(s) |
|----------|--------------|---------------------|
| Foundry | `account` | `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com` |
| Azure AI Search | `searchService` | `privatelink.search.windows.net` |
| Azure Cosmos DB | `Sql` | `privatelink.documents.azure.com` |
| Azure Storage | `blob` | `privatelink.blob.core.windows.net` |
| Key Vault | `vault` | `privatelink.vaultcore.azure.net` |
| Fabric workspace | (per Fabric docs) | Fabric private-link zone(s) |

### 5.7 Logical Diagram (textual)

```
 Admin/Dev machine  (Azure P2S VPN client; client DNS -> Private Resolver inbound IP)
     |
     v
 +===========================================================+
 |                    Customer VNet (eastus2)                |
 |                                                           |
 |  GatewaySubnet ── [VPN Gateway (P2S)]                     |
 |  snet-dnsresolver ── [Azure DNS Private Resolver]         |
 |                                                           |
 |  snet-pe ── [Fabric PE] <───────── Microsoft Fabric workspace (public access DISABLED)
 |          ├─ [Foundry PE]                 ^                |
 |          ├─ [Storage PE]                 | Foundry agent -> Fabric data agent
 |          ├─ [AI Search PE (to westus2)]  | (workspace private FQDN, Entra OBO)
 |          ├─ [Cosmos DB PE]               |                |
 |          └─ [Key Vault PE]        +------------------------------+
 |                                   | Azure AI Foundry             |
 |                                   |  Agent Service (data agent)  | (public DISABLED)
 |  snet-agents (/27, delegated      |  + inbound Private Endpoint  |
 |     Microsoft.App/environments)   +------------------------------+
 |     └── VNet injection ───────────┘   |        |         |
 +===========================================================+
                                     Storage   AI Search    Cosmos DB   (+ Key Vault)
                                     (BYO NEW; Storage/Cosmos/KV in eastus2, Search in
                                      westus2; all private endpoints, public DISABLED)
```

## 6. Target Build — Fully Private (sensitive data)

- Fabric: **workspace-level private link**, public access **disabled**; **P2S VPN + Azure DNS
  Private Resolver** for inbound access (no Bastion).
- Foundry Agent Service: **Standard Setup with Private Networking** — public access disabled,
  inbound private endpoint, `snet-agents` VNet injection.
- BYO **new Storage + AI Search + Cosmos DB**, each locked down with private endpoints + RBAC
  (Search runs in westus2 with a cross-region private endpoint — see §5.3).
- Foundry agent → Fabric data agent via a **RemoteTool connection over the workspace-level private
  link** (Entra OBO) — see §5.2. Optional reverse Fabric → Foundry MPE only if Fabric must call Foundry.
- Key Vault locked down with private endpoint.
- Private DNS zones created + linked; DNS Private Resolver serving P2S clients.

## 7. Design Decisions / Options

| Decision | Chosen | Notes |
|----------|--------|-------|
| Region | **eastus2** | All resources + VNet co-located. |
| Inbound path into VNet | **VPN Gateway — P2S** | Single dev machine for testing. No Bastion. |
| P2S name resolution | **Azure DNS Private Resolver** | P2S clients can't use 168.63.129.16 directly. |
| Fabric private link scope | **Workspace-level** | Scoped to this workload. |
| VNet | **New greenfield, `192.168.0.0/16`** | Agent injection subnet must be 172.x/192.x (10.x rejected). |
| BYO resources | **Create new** Storage/Search/Cosmos | Required by Standard Setup; shared not allowed with private networking. |
| IaC tooling | **Bicep** | — |
| Private DNS | **New Azure Private DNS zones** | Linked to VNet; resolver for P2S. |
| Foundry setup | **Agent Service, Standard + Private Networking** | BYO Storage/Search/Cosmos required. |
| Foundry auth | **Managed identity (Entra)** | Prefer over keys. |

## 8. Resolved Inputs (as deployed)
- [x] **VNet address space:** `192.168.0.0/16` — subnets `snet-pe` (`.0.0/24`), `snet-agents`
  (`.1.0/27`), `snet-dnsresolver` (`.1.32/28`), `GatewaySubnet` (`.2.0/27`). **Not** 10.x.
- [x] **P2S VPN client auth:** **Entra ID** (OpenVPN), client pool `172.16.0.0/24`.
- [x] **Cosmos DB throughput:** provisioned (Standard agent setup requires ≥ 3000 RU/s across its 5
  containers).
- [x] **Resource group / naming:** `rg-fabric-foundry-eus2` (eastus2); Foundry account `ffndryfsnn`,
  project `fabricagentfsnn`.
- [x] **Model deployment(s):** `gpt-5.1` bound to the agent (also `gpt-5.6-sol`,
  `text-embedding-3-small` deployed).

## 9. References (Microsoft Learn)
- Set up and use workspace-level private links (Microsoft Fabric).
- Connect agents to Microsoft Fabric with Fabric IQ — virtual network support (Azure AI Foundry):
  `learn.microsoft.com/azure/foundry/agents/how-to/tools/fabric-iq#virtual-network-support`.
- Consume a Fabric data agent from Microsoft Foundry (preview).
- Connect to external / on-premises data sources using managed private endpoints (Microsoft Fabric).
- Set up private networking for Foundry Agent Service (templates) — VNet injection, BYO resources, DNS zones.
- Deep dive into Foundry Agent Service networking — subnet sizing and IP allocation.
