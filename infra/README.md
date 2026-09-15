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

### Fabric (portal / Fabric admin — NOT Bicep)
Fabric private link and workspace settings are **not** ARM-deployable; configure them in Fabric:
1. **Fabric Admin portal → Tenant settings** → enable **Azure Private Link** (provisions the tenant/workspace private-link resource).
2. On the target **workspace** → **Network security → Workspace-level private link** → create the
   private endpoint into `snet-pe`, then **disable public access** for the workspace.
3. Fabric → **Managed private endpoints** → create an MPE targeting the Foundry resource; **approve**
   the pending connection on the Foundry resource (Networking → Private endpoint connections).

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
