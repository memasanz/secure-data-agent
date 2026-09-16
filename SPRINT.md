# Sprint: Fabric Lakehouse → Data Agent → Foundry (MCP) — Private Networking

**Owner:** autonomous execution (Copilot CLI)
**Started:** 2026-09-15
**Repo:** memasanz/secure-data-agent
**Subscription:** ME-MngEnvMCAP272547-memasanz-1 (`7ee2b43a-...`)
**Resource group:** `rg-fabric-foundry-eus2` · **Region:** eastus2

## Goal
Deploy the remaining Fabric infra, generate sample data into a Lakehouse, create a Fabric
data agent over it, and connect that data agent through **MCP** to an agent built in **Azure AI
Foundry** — all within the private-network design already deployed (Stages 01–03).

## Key context / constraints
- Stages 01 (network), 02 (VPN + DNS resolver), 03 (Foundry + BYO Storage/Search/Cosmos) are **deployed**.
- **Foundry account `ffndryfsnn`** has `publicNetworkAccess=Disabled`, `disableLocalAuth=true`
  (AAD only). Endpoint: `https://ffndryfsnn.cognitiveservices.azure.com/`.
- Search is BYO in **westus2** (`ffndry-search-westus2`, basic) — eastus2/westus3 lacked capacity.
- Model deployed: **gpt-5.1** (GlobalStandard, 2025-11-13) in project `fabricagent`.
- Fabric REST (`api.fabric.microsoft.com`) is reachable publicly; identity is
  `admin@MngEnvMCAP272547.onmicrosoft.com` (`03283c82-...`).

## Decisions
- **D1** — Fabric capacity: **F4**, eastus2, admin = current user.
- **D2** — Build all Fabric content over the **public** Fabric REST API; **defer** the workspace
  deny-public-access lockdown to the final hardening phase so automation isn't locked out.
- **D3** — Foundry stays **private** (`publicNetworkAccess=Disabled`). The P2S VPN is connected and
  the private endpoints (`192.168.0.6/.7/.8`) are reachable on 443. The machine is corp-managed with
  NRPT rules that force `*.cognitiveservices/*.services.ai/*.search` to corporate DNS (public IPs),
  and there is no local admin to edit hosts/NRPT — so **system DNS returns public IPs**. Workaround
  for Phase 4 data-plane calls: use `curl --resolve <host>:443:<privateIP>` (correct SNI + cert, no
  admin, no posture change). Temporary public toggle is a last-resort fallback only.
- **D4** — Fabric Data Agent + MCP are new/preview. Attempt via REST; if a step is interactive-only,
  mark it **BLOCKED** with exact manual instructions rather than fake success.

## Phases & acceptance criteria

### Phase 1 — Deploy Fabric infra
- [ ] 1.1 Deploy **capacity** (`04-fabric/capacity.bicep`, F4) → Succeeded
- [ ] 1.2 Create **workspace**, assign to capacity → capture `workspaceId`
- [ ] 1.3 Deploy **workspace private link** (`04-fabric/main.bicep`) → PE in snet-pe + DNS
      _(prereqs: Microsoft.Fabric RP registered; tenant network-rules toggle — may be BLOCKED)_

### Phase 2 — Sample data → Lakehouse
- [ ] 2.1 Generate synthetic **retail sales** dataset (CSV/Parquet)
- [ ] 2.2 Create a **Lakehouse** in the workspace
- [ ] 2.3 Load the data into the Lakehouse (OneLake / Fabric REST); confirm a queryable table

### Phase 3 — Fabric data agent
- [ ] 3.1 Create a **Fabric data agent** over the Lakehouse
- [ ] 3.2 Configure the data source + instructions; validate a sample question

### Phase 4 — Foundry agent + MCP
- [ ] 4.1 Build an **agent in Foundry** (gpt-5.1, project `fabricagent`)
- [ ] 4.2 Connect the **Fabric data agent via MCP** to the Foundry agent

### Phase 5 — Verify + harden
- [ ] 5.1 End-to-end: ask the Foundry agent a question answered from Fabric data
- [ ] 5.2 Harden: restore Foundry `publicNetworkAccess=Disabled`; optionally deny Fabric public access

## Status log
| Time (UTC) | Phase | Update |
|------------|-------|--------|
| 2026-09-15T~02:05 | 0 | Sprint plan created; starting Phase 1. |
| 2026-09-15T~02:40 | 0 | VPN connected; PEs reachable on 443. Corp NRPT overrides push privatelink names to public DNS and no local admin — system DNS stays public. Foundry to stay private; Phase 4 will use `curl --resolve`. Capacity set to F4. |
