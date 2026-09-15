# Spec: Private Microsoft Fabric + Azure AI Foundry Network Architecture

**Status:** Draft
**Last updated:** 2026-09-15
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
- Fabric must **call the Foundry data agent** (Foundry Agent Service, Standard + Private Networking).
- **BYO data resources: create NEW dedicated** Storage + AI Search + Cosmos DB (required — see §5.3).
- IaC: **Bicep**.
- **VNet:** new greenfield VNet.
- **DNS:** new **Azure Private DNS zones**, plus an **Azure DNS Private Resolver** so the P2S client
  can resolve private FQDNs (see §5.6).

## 2. Scope

In scope:
- Fabric workspace inbound access lockdown (private link + public access disabled).
- Client/admin connectivity into the private network (**VPN Gateway**, P2S/S2S).
- Fabric → Azure AI Foundry private connectivity (managed private endpoints).
- Locking down Foundry and its dependent resources (Storage, Key Vault, AI Search).

Out of scope (for now):
- CI/CD pipelines, DNS integration with on-prem, and identity/RBAC design detail.
- Data ingestion sources beyond Foundry dependencies.

## 3. Key Concept: Two Independent Private-Link Directions

There are **two separate** connectivity concerns. Conflating them leads to over-building.

| Direction | What it governs | Mechanism | Needs customer VNet/VPN? |
|-----------|-----------------|-----------|--------------------------|
| **Inbound** to Fabric | How users/admins/clients reach the locked-down Fabric portal & APIs | Fabric **private endpoint** in a customer VNet | ✅ Yes — plus a way *into* the VNet |
| **Outbound** from Fabric | How Fabric data workloads reach Azure resources (Foundry, Storage, etc.) | Fabric **managed private endpoint (MPE)** in a Microsoft-managed VNet | ❌ No — MPE lives in Microsoft-managed VNet |

## 4. Requirements

### 4.1 Functional
- FR1: Fabric workspace reachable only over private link; public internet access disabled.
- FR2: Authorized users/admins can reach the private Fabric endpoint from a controlled path.
- FR3: Fabric workloads can call Azure AI Foundry model/inference endpoints privately.
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

### 5.2 Outbound — Fabric → Foundry
- Create a **managed private endpoint (MPE)** from Fabric targeting the Foundry resource.
- **Approve** the pending private endpoint connection on the Foundry side.
- Traffic path: Fabric → Microsoft-managed VNet → private endpoint → Foundry (no internet).
- **No customer VNet or VPN required for this leg.**

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
- **Data-plane RBAC** — assign to the Foundry project managed identity:
  - Cosmos DB → **Cosmos DB Built-in Data Contributor**
  - AI Search → **Search Index Data Contributor** + **Search Service Contributor**
  - Storage → **Storage Blob Data Contributor** (`azureml-blobstore`) / **Storage Blob Data Owner** (`agents-blobstore`)
- Register required resource providers: `Microsoft.KeyVault`, `Microsoft.CognitiveServices`,
  `Microsoft.Storage`, `Microsoft.MachineLearningServices`, `Microsoft.Search`, `Microsoft.Network`,
  `Microsoft.App`, `Microsoft.ContainerService` (+ `Microsoft.Bing` if the Bing tool is used).

**Fabric → Foundry leg:** Fabric reaches the (now private) Foundry endpoint via a Fabric
**managed private endpoint (MPE)**, which you **approve** on the Foundry side. This MPE is separate
from the agent-service VNet injection above.

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
| Azure AI Foundry (Agent Service) | Private endpoint + VNet injection, public access disabled | Fabric **managed private endpoint** (approved) |
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
 |  snet-pe ── [Fabric PE] ─────────> Microsoft Fabric (public access DISABLED)
 |          ├─ [Foundry PE]                     |            |
 |          ├─ [Storage PE]                     | Managed Private Endpoint (approved)
 |          ├─ [AI Search PE]                   v            |
 |          ├─ [Cosmos DB PE]        +------------------------------+
 |          └─ [Key Vault PE]        | Azure AI Foundry             |
 |                                   |  Agent Service (data agent)  | (public DISABLED)
 |  snet-agents (/27, delegated      |  + inbound Private Endpoint  |
 |     Microsoft.App/environments)   +------------------------------+
 |     <── VNet injection ───────────┘   |        |         |
 +===========================================================+
                                     Storage   AI Search   Cosmos DB   (+ Key Vault)
                                     (BYO NEW, all private endpoints, public DISABLED)
```

## 6. Target Build — Fully Private (sensitive data)

- Fabric: **workspace-level private link**, public access **disabled**; **P2S VPN + Azure DNS
  Private Resolver** for inbound access (no Bastion).
- Foundry Agent Service: **Standard Setup with Private Networking** — public access disabled,
  inbound private endpoint, `snet-agents` VNet injection.
- BYO **new Storage + AI Search + Cosmos DB**, each locked down with private endpoints + RBAC.
- Fabric → Foundry via **managed private endpoint** (approved).
- Key Vault locked down with private endpoint.
- Private DNS zones created + linked; DNS Private Resolver serving P2S clients.

## 7. Design Decisions / Options

| Decision | Chosen | Notes |
|----------|--------|-------|
| Region | **eastus2** | All resources + VNet co-located. |
| Inbound path into VNet | **VPN Gateway — P2S** | Single dev machine for testing. No Bastion. |
| P2S name resolution | **Azure DNS Private Resolver** | P2S clients can't use 168.63.129.16 directly. |
| Fabric private link scope | **Workspace-level** | Scoped to this workload. |
| VNet | **New greenfield** | Created in this deployment. |
| BYO resources | **Create new** Storage/Search/Cosmos | Required by Standard Setup; shared not allowed with private networking. |
| IaC tooling | **Bicep** | — |
| Private DNS | **New Azure Private DNS zones** | Linked to VNet; resolver for P2S. |
| Foundry setup | **Agent Service, Standard + Private Networking** | BYO Storage/Search/Cosmos required. |
| Foundry auth | **Managed identity (Entra)** | Prefer over keys. |

## 8. Open Questions / Remaining Inputs
- [ ] VNet address space + subnet CIDRs (e.g., `10.20.0.0/16` with the four subnets in §5.4).
- [ ] P2S VPN client auth method: **Entra ID** (recommended) vs certificate-based.
- [ ] Cosmos DB throughput mode: **Serverless** (cheaper for test) vs Provisioned (≥3000 RU/s).
- [ ] Naming convention / resource group name for the deployment.
- [ ] Model deployment(s) to bind to the agent (e.g., gpt-4o) — name + capacity.

## 9. References (Microsoft Learn)
- Set up and use workspace-level private links (Microsoft Fabric).
- Connect to external / on-premises data sources using managed private endpoints (Microsoft Fabric).
- Create an allow list using managed private endpoints (Microsoft Fabric).
- Set up private networking for Foundry Agent Service (templates) — VNet injection, BYO resources, DNS zones.
- Deep dive into Foundry Agent Service networking — subnet sizing and IP allocation.
