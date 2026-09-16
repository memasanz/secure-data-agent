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
| 04 | `04-fabric/` | **Fabric capacity (F SKU)** + **workspace-level private link** + private endpoint (`snet-pe`) + `privatelink.fabric.microsoft.com` DNS | This repo |

Stage 03 reuses the upstream **microsoft-foundry/foundry-samples** template
(`15-private-network-standard-agent-setup`) rather than re-implementing its fragile
capability-host logic. Stages 01/02 add the VNet and inbound access the sample omits.

## Prerequisites

- Azure CLI 2.80+, Bicep 0.43+, `git`.
- Rights to create the resources + assign RBAC (Owner or equivalent on the RG).
- The resource providers listed in the spec registered on the subscription.

## Deploy

```powershell
$RG  = 'rg-fabric-foundry-eus2'
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

#### If names still resolve to public IPs (corp-managed machines)

On a corporate-managed device, **NRPT policies** can force names like `*.cognitiveservices.azure.com`,
`*.services.ai.azure.com`, and `*.search.windows.net` to **corporate DNS**, which returns the **public**
IPs. Because those services have `publicNetworkAccess=Disabled`, the public IPs are unreachable and the
Foundry portal shows **"Private network access required"** — even though the VPN tunnel and the DNS
Private Resolver are working (a plain `nslookup <host> 192.168.1.36` returns the private IP, but the
system default resolver does not). These NRPT rules are more specific than the VPN's catch-all rule, so
they win; fixing NRPT normally needs admin/GPO changes.

Workaround — override just the specific FQDNs in the **hosts file** (it takes precedence over NRPT/DNS):

```powershell
# Requires the VPN connected. Self-elevates. Reads the private DNS zones and maps each
# private-endpoint FQDN -> its private IP inside a clearly marked, reversible block.
./infra/04-fabric/set-hosts-overrides.ps1

# Undo:
./infra/04-fabric/set-hosts-overrides.ps1 -Remove
```

For scripted/data-plane calls you can avoid touching DNS entirely by pinning the IP per request:
`curl --resolve <host>:443:<privateIP> https://<host>/...` (correct SNI + valid cert, no admin).

### Fabric (workspace-level private link)
Fabric tenant/workspace *settings* are configured in Fabric, but the **private-link resource,
private endpoint, and DNS are now deployed by Stage 04** (`infra/04-fabric/`).
This workload uses **workspace-level** private link (scoped to one workspace), **not** tenant-level.

> ⚠️ **Do not enable the tenant-level "Azure Private Link" setting.** That is the *tenant-level*
> flow and locks down **every** workspace in the tenant. Workspace-level uses a different toggle
> (`Configure workspace-level inbound network rules`) that only *permits* per-workspace rules.

#### Inbound — lock down the workspace (workspace-level private link)
1. **Prereq — capacity**: the workspace must be on a **Fabric capacity (F SKU)**. P (Premium) and
   trial capacities are **not** supported. Create one with Bicep — first edit
   `infra/04-fabric/capacity.bicepparam` and set:
   - `capacityName` (lowercase letters/digits, 3–63 chars) and `skuName` (e.g. `F4`);
   - `adminMembers` — **replace the `<CAPACITY_ADMIN_UPN_OR_OBJECT_ID>` placeholder** with your Entra
     UPN (e.g. `you@contoso.onmicrosoft.com`) or object ID. This is **required**; deployment fails on
     the placeholder.
   ```powershell
   az deployment group create -g $RG `
     -f infra/04-fabric/capacity.bicep -p infra/04-fabric/capacity.bicepparam
   ```
   > **Cost:** F-SKU capacities bill hourly while running. **Pause** the capacity when idle
   > (portal → capacity → Pause, or `az resource invoke-action --action pause`).

   Then create the workspace and assign it to the capacity:
   ```powershell
   ./infra/04-fabric/create-workspace.ps1 -ListCapacities            # find the F-SKU capacity id (GUID)
   ./infra/04-fabric/create-workspace.ps1 -DisplayName 'fabric-foundry-ws' -CapacityId <capacity-guid>
   ```
   `create-workspace.ps1` prints the new **workspace ID** — use it in the next steps.
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

#### Foundry → Fabric — connect the agent to the data agent (workspace-level private link)
8. Once the workspace denies public access, the **native Foundry Fabric tool no longer works** — it
   calls the shared `api.fabric.microsoft.com` host, which is now blocked (runs fail with **424**).
   Instead, use the **Fabric IQ** tool with a **RemoteTool** connection that targets the
   **workspace-specific private FQDN** and passes the signed-in user's Entra token (OBO). The Foundry
   agent runtime is VNet-injected, so it resolves that FQDN to the private endpoint IP and reaches
   the workspace entirely over the workspace-level private link:

   | Connection property | Value |
   |---------------------|-------|
   | `category` | `RemoteTool` |
   | `authType` | `UserEntraToken` (identity passthrough / OBO) |
   | `target` | `https://{workspaceId-nodashes}.z{xy}.w.api.fabric.microsoft.com/v1/mcp/workspaces/{workspaceId}/dataagents/{dataAgentId}/agent` |
   | `audience` | `https://analysis.windows.net/powerbi/api` (Power BI resource; `DataAgent.Execute.All` scope) |

   Create it via REST (`PUT .../projects/{project}/connections/{name}?api-version=2025-10-01-preview`)
   or `azd ai connection create ... --kind remote-tool --auth-type user-entra-token`, then reference
   it from the agent through `FabricIQPreviewTool(project_connection_id=...)`
   (SDK `azure-ai-projects >= 2.2.0`). A runnable end-to-end example is
   [`../data/test_fabriciq_vnet.py`](../data/test_fabriciq_vnet.py).

   > ⚠️ **Wrong-audience trap:** a connection with the correct `target` but `audience =
   > https://api.fabric.microsoft.com` authenticates but is rejected for data-agent execution → the
   > run fails with **424**. Use the Power BI audience above.
   >
   > ℹ️ **The data agent must be (re)published** before any external caller can run it — a stale
   > published stage makes every external run fail while the interactive draft still works.

9. **(Optional, reverse direction) Fabric → Foundry managed private endpoint.** Only needed if
   *Fabric* must privately call the *Foundry* resource (e.g. to use a Foundry-hosted model from
   Fabric) — it is **not** required for the Foundry→Fabric data-agent query flow above. Fabric →
   **Managed private endpoints** → create an MPE targeting the Foundry resource (`ffndryfsnn`) and
   **approve** it on the Foundry side (Networking → Private endpoint connections). This MPE lives in a
   Microsoft-managed VNet — no customer VNet/VPN needed for this leg, and it is not ARM-deployable.

> Docs: [Set up workspace-level private links](https://learn.microsoft.com/fabric/security/security-workspace-level-private-links-set-up)
> · [Enable workspace inbound access protection](https://learn.microsoft.com/fabric/security/security-workspace-enable-inbound-access-protection)
> · [Fabric IQ tool — virtual network support](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/fabric-iq#virtual-network-support)

### RBAC for the agent (if not handled by the sample)
Assign to the Foundry project managed identity: Cosmos DB Built-in Data Contributor;
Search Index Data Contributor + Search Service Contributor; Storage Blob Data Contributor/Owner.

### Data + agent wiring (from a P2S-connected machine)
The Python scripts in [`../data/`](../data/) create the sample data, publish the Fabric data agent,
create the Foundry connection, and verify the end-to-end query over the private link:

```powershell
python data/generate_retail_sales.py      # synthetic retail dataset -> data/out/*.csv
python data/load_to_lakehouse.py          # load CSVs into the lakehouse
python data/create_data_agent.py          # create + PUBLISH the Fabric data agent
python data/setup_fabric_connection.py    # create the Foundry RemoteTool connection + agent
$env:PYTHONIOENCODING = 'utf-8'
python data/test_fabriciq_vnet.py         # end-to-end Foundry -> Fabric test (expects '5,000 rows')
```

## Notes / gotchas
- **Agent subnet address space**: keep it in 172.x / 192.x. This is why the VNet is 192.168.0.0/16.
- **VPN client pool** (`172.16.0.0/24`) must not overlap the VNet.
- **VPN gateway is slow** to provision (~30-45 min). Set `deployVpnGateway=false` in Stage 02 to
  iterate on the DNS resolver alone first.
- **Cosmos throughput**: Standard agent setup needs ≥ 3000 RU/s (5 containers × 1000). The sample
  provisions the account; the agent service creates the containers.
