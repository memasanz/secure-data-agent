# Infrastructure — Private Fabric + Foundry Agent Service

Bicep to stand up the private-networking architecture described in
[`../fabric-foundry-private-network-spec.md`](../fabric-foundry-private-network-spec.md).

Everything targets **eastus2** and a **single resource group**. The VNet uses
**192.168.0.0/16** because the Foundry Agent Service injection subnet must be in the
**172.x / 192.x** range (the platform rejects 10.x).

## Layout

| Stage | Path | What it deploys | Authored |
|-------|------|-----------------|----------|
| 01 | `01-network/` | VNet + 4 subnets (`snet-pe`, `snet-agents`, `snet-dnsresolver`, `GatewaySubnet`) + NSGs | This repo |
| 02 | `02-access/` | **P2S VPN Gateway** (Entra auth) + **Azure DNS Private Resolver** | This repo |
| 03 | `03-foundry/` | Foundry account + **BYO Storage/Search/Cosmos** + private endpoints + agent capability host | Upstream Microsoft sample |
| 04 | `04-fabric/` | **Fabric workspace-level private link** + private endpoint (`snet-pe`) + `privatelink.fabric.microsoft.com` DNS | This repo |

Stage 03 reuses the upstream **microsoft-foundry/foundry-samples** template
(`15-private-network-standard-agent-setup`) rather than re-implementing its fragile
capability-host logic. Stages 01/02 add the VNet and inbound access the sample omits.

## Prerequisites

- Azure CLI 2.80+, Bicep 0.43+, `git`.
- Rights to create the resources + assign RBAC (Owner or equivalent on the RG).
- The resource providers listed in the spec registered on the subscription.

## Deploy

```powershell
$RG  = 'rg-fabric-foundry-priv'
$LOC = 'eastus2'
az group create -n $RG -l $LOC

# --- Stage 01: network ---
az deployment group create -g $RG `
  -f infra/01-network/main.bicep -p infra/01-network/main.bicepparam

# capture outputs
$net = az deployment group show -g $RG -n main --query properties.outputs -o json | ConvertFrom-Json
$vnetId        = $net.vnetId.value
$dnsSubnetId   = $net.dnsResolverSubnetId.value
$gwSubnetId    = $net.gatewaySubnetId.value

# --- Stage 02: access (VPN + DNS resolver). VPN gateway takes ~30-45 min. ---
az deployment group create -g $RG `
  -f infra/02-access/main.bicep `
  -p vnetId=$vnetId dnsResolverSubnetId=$dnsSubnetId gatewaySubnetId=$gwSubnetId

$acc = az deployment group show -g $RG -n main --query properties.outputs -o json | ConvertFrom-Json
$resolverIp = $acc.dnsResolverInboundIp.value

# Point the VNet (and therefore P2S clients) at the private resolver so
# privatelink.* names resolve over the VPN.
az network vnet update -g $RG -n vnet-fabric-foundry --dns-servers $resolverIp

# --- Stage 03: Foundry + BYO + private endpoints ---
./infra/03-foundry/get-foundry-sample.ps1
# edit infra/03-foundry/foundry.parameters.example.json -> set existingVnetResourceId=$vnetId
az deployment group create -g $RG `
  -f infra/03-foundry/sample/main.bicep `
  -p infra/03-foundry/foundry.parameters.example.json
```

> The Stage 03 sample creates the private DNS zones for Foundry/Search/Cosmos/Storage and
> links them to the VNet. Because the DNS Private Resolver lives in the same VNet, those zones
> resolve for P2S clients automatically once the VNet DNS is set to the resolver IP (above).

## After deployment

### Connect your machine (P2S VPN)
1. Azure portal → the VPN gateway → **Point-to-site configuration** → **Download VPN client**.
2. Import the profile into the **Azure VPN Client** and sign in with Entra ID.
3. Verify: `nslookup <foundry-account>.services.ai.azure.com` resolves to a **192.168.x** (private) IP.

### Fabric (workspace-level private link)
Fabric tenant/workspace *settings* are configured in Fabric, but the **private-link resource,
private endpoint, and DNS are now deployed by Stage 04** (`infra/04-fabric/`).
This workload uses **workspace-level** private link (scoped to one workspace), **not** tenant-level.

> ⚠️ **Do not enable the tenant-level "Azure Private Link" setting.** That is the *tenant-level*
> flow and locks down **every** workspace in the tenant. Workspace-level uses a different toggle
> (`Configure workspace-level inbound network rules`) that only *permits* per-workspace rules.

#### Inbound — lock down the workspace (workspace-level private link)
1. **Prereq — capacity**: the workspace must be on a **Fabric capacity (F SKU)**. P (Premium) and
   trial capacities are **not** supported. (Workspace settings → License info.)
2. **Prereq — tenant toggle**: a Fabric admin enables **Tenant settings → `Configure workspace-level
   inbound network rules`** (Enable workspace inbound access protection). This is *not* tenant-level
   private link.
3. **Prereq — resource provider** (first time in the tenant): in the Azure subscription, re-register
   **`Microsoft.Fabric`** (Subscription → Resource providers → `Microsoft.Fabric` → **Re-register**).
4. Note your **workspace ID** (from the portal URL after `/groups/`) and **tenant ID**
   (Fabric portal → **?** → About Power BI → `ctid`).
5. **Deploy Stage 04** — this creates the Fabric private-link resource
   (`Microsoft.Fabric/privateLinkServicesForFabric`), the **private endpoint into `snet-pe`**
   (subresource `workspace`), and the **`privatelink.fabric.microsoft.com`** DNS zone + VNet link +
   DNS group. Set `workspaceId` in the bicepparam first:
   ```powershell
   # edit infra/04-fabric/main.bicepparam -> set workspaceId = '<your-fabric-workspace-guid>'
   az deployment group create -g $RG `
     -f infra/04-fabric/main.bicep -p infra/04-fabric/main.bicepparam
   ```
   > Because the DNS zone is linked to the VNet and the DNS Private Resolver lives there, the Fabric
   > FQDN resolves for P2S clients automatically (same pattern as Foundry/Search/Storage/Cosmos).
6. **Verify from a P2S-connected machine** (no Bastion/VM needed — the Learn article uses Bastion+VM
   only because it assumes no existing inbound path; you already have the VPN + resolver):
   `nslookup {workspaceid}.z{xy}.w.api.fabric.microsoft.com` → returns a **private** IP
   (`workspaceid` = workspace object ID without dashes; `xy` = its first two characters).
7. **Deny public access**: run the Stage 04 script (REST API — this step is **not** ARM-deployable).
   Only run it **after** the private endpoint is verified over the VPN, or you can lock yourself out:
   ```powershell
   ./infra/04-fabric/set-deny-public-access.ps1 -WorkspaceId <your-fabric-workspace-guid>
   # revert with:  -Action Allow
   ```
   Equivalent portal path: Workspace settings → **Inbound networking** → **Workspace connection
   settings** → **Allow connections from selected networks and workspace level private links** →
   **Apply**. Can take up to ~30 min to take effect.

#### Outbound — Fabric → Foundry (managed private endpoint)
8. Fabric → **Managed private endpoints** → create an MPE targeting the Foundry resource
   (`ffndryfsnn`); **approve** the pending connection on the Foundry side (Networking → Private
   endpoint connections). This MPE lives in a Microsoft-managed VNet — **no** customer VNet/VPN
   required for this leg, and it is **not** ARM-deployable.

> Docs: [Set up workspace-level private links](https://learn.microsoft.com/fabric/security/security-workspace-level-private-links-set-up)
> · [Enable workspace inbound access protection](https://learn.microsoft.com/fabric/security/security-workspace-enable-inbound-access-protection)

### RBAC for the agent (if not handled by the sample)
Assign to the Foundry project managed identity: Cosmos DB Built-in Data Contributor;
Search Index Data Contributor + Search Service Contributor; Storage Blob Data Contributor/Owner.

## Notes / gotchas
- **Agent subnet address space**: keep it in 172.x / 192.x. This is why the VNet is 192.168.0.0/16.
- **VPN client pool** (`172.16.0.0/24`) must not overlap the VNet.
- **VPN gateway is slow** to provision (~30-45 min). Set `deployVpnGateway=false` in Stage 02 to
  iterate on the DNS resolver alone first.
- **Cosmos throughput**: Standard agent setup needs ≥ 3000 RU/s (5 containers × 1000). The sample
  provisions the account; the agent service creates the containers.
