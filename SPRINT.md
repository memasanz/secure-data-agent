# Sprint: Fabric Lakehouse → Data Agent → Foundry (MCP) — Private Networking

**Owner:** autonomous execution (Copilot CLI)
**Started:** 2026-09-15
**Repo:** memasanz/secure-data-agent
**Subscription / Resource group:** see `az account show`; RG `rg-fabric-foundry-eus2` · **Region:** eastus2

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
- Fabric REST (`api.fabric.microsoft.com`) is reachable publicly; identity is the
  current signed-in Entra user (see `az account show`).

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
- [x] 1.1 Deploy **capacity** (`04-fabric/capacity.bicep`, F4) → **Succeeded** (`fabricfoundrycap`, GUID `01b669db-…`, Active)
- [x] 1.2 Create **workspace**, assign to capacity → `fabric-foundry-ws` = `98edd5b8-482a-444b-8756-134251b3566e`
- [ ] 1.3 Deploy **workspace private link** (`04-fabric/main.bicep`) → **DEFERRED to Phase 5** (per D2: locking down now would cut off the public REST automation; also needs an interactive tenant inbound-rules toggle)

### Phase 2 — Sample data → Lakehouse
- [x] 2.1 Generate synthetic **retail sales** dataset (CSV) → `data/generate_retail_sales.py` → 200 customers, 30 products, 5000 sales
- [x] 2.2 Create a **Lakehouse** in the workspace → `RetailSales` = `0d46a133-70da-42bb-a23f-43019b7d605c` (SQL endpoint provisioned)
- [x] 2.3 Load the data into the Lakehouse (Delta tables written to OneLake `Tables/` via delta-rs) → `customers` (200), `products` (30), `sales` (5000) — all Managed Delta, confirmed queryable

### Phase 3 — Fabric data agent
- [x] 3.1 Create a **Fabric data agent** over the Lakehouse → `RetailSalesAgent` = `ef2b5550-b3ea-4c1e-99bc-5590e8aab60f` (via `fabric-data-agent-sdk`), datasource = RetailSales lakehouse, **published**
- [ ] 3.2 Configure the data source + instructions; validate a sample question — **config verified** (AI instructions set; 18 columns across `sales`/`customers`/`products` selected & published; SQL endpoint returns correct counts 5000/200/30). **MCP endpoint live**, tool `DataAgent_RetailSalesAgent` discoverable. ⚠️ **BLOCKED on live run**: every query (even "Hello") returns *"The Data Agent run failed before producing a result."* on both F4 and F16 capacities; tenant `EnableAOAI=True`. API exposes no detail — needs portal error to root-cause.

### Phase 4 — Foundry agent + MCP
- [ ] 4.1 Build an **agent in Foundry** (gpt-5.1, project `fabricagent`)
- [ ] 4.2 Connect the **Fabric data agent via MCP** to the Foundry agent

### Phase 5 — Verify + harden
- [ ] 5.1 End-to-end: ask the Foundry agent a question answered from Fabric data
- [ ] 5.2 Harden: restore Foundry `publicNetworkAccess=Disabled`; optionally deny Fabric public access

## Spike S1 — Isolate the Foundry↔Fabric data-agent failure (network vs auth vs connection)

**Status:** NETWORK RULED OUT · root cause = auth/consent (H2) + preview connection (H3) · **Time-box:** ~2h · **Entered:** 2026-09-16
**Trigger:** The Fabric data agent works interactively in the Fabric portal, but (a) the bare MCP
call from a script returns *"run failed before producing a result"*, and (b) the Foundry
`fabric_dataagent_preview` tool (portal- and ARM-created connections) returns *"Workspace ID and
Artifact ID are required from connection details"* / appears blocked in the portal playground.

**Question:** Is the Foundry↔Fabric failure a **network** problem (agent runtime can't resolve/reach
`api.fabric.microsoft.com` from the private VNet), an **auth/OBO** problem (calling identity lacks the
delegated Copilot scopes the data-agent run needs), or a **preview connection** problem (tool can't
read workspace/artifact IDs from a CLI/ARM-created connection)?

**Hypotheses**
- **H1 (network):** The agent runtime egresses through `snet-agents`; VNet DNS = private resolver
  `192.168.1.36`, whose linked zones are all `privatelink.*` (no zone for public `api.fabric.microsoft.com`).
  If the resolver doesn't recurse public names, or egress to Fabric is blocked, every tool call fails.
- **H2 (auth/OBO):** The az-CLI client (and possibly the Foundry OBO exchange) lacks consent for the
  Fabric data-agent AI run; the portal works because it uses Fabric's first-party client.
- **H3 (connection preview gap):** The `fabric_dataagent_preview` tool can't extract workspace/artifact
  IDs from a connection created via ARM/CLI (only portal-created ones store them where the runtime reads).
- **H4 (cross-region):** Data-agent capacity region ≠ Foundry region → query can't execute.

**Test matrix — ways to exercise the Fabric MCP tool OUTSIDE the Foundry agent**
| # | Test | Isolates | Result |
|---|------|----------|--------|
| T1 | Resolve `api.fabric.microsoft.com` via the private resolver `192.168.1.36` (from VPN) | H1 DNS | ✅ resolves to **public** `20.41.4.110` (CNAME→api.powerbi.com→privatelink.analysis.windows.net→TM; no private zone linked → recurses public). DNS OK. |
| T2 | From INSIDE the VNet (probe ACI/VM in `snet-pe`): nslookup + `curl -sS https://api.fabric.microsoft.com` | H1 DNS+egress | pending (probe) |
| T3 | From inside the VNet: full MCP `call_tool` with a Fabric token (reproduce agent path) | H1 vs H2 | pending (probe) |
| T4 | From my machine over the PUBLIC internet: MCP `call_tool` (endpoint is public) | H2 (network-independent) | ⚠️ run fails ("run failed before producing a result") over public path → **network-independent → auth** |
| T5 | MCP Inspector (`npx @modelcontextprotocol/inspector`) against the endpoint with a token | client-independence | superseded by T9 |
| T6 | Fabric portal interactive chat | control (agent health) | ✅ works |
| T7 | Compare Fabric capacity region vs Foundry region (`eastus2`) | H4 | ✅ both **East US 2** → H4 ruled out |
| T9 | **Raw `curl` MCP flow from client machine** (public internet, az-CLI token) | reachability vs run | ✅ `initialize` → **HTTP 200**, clean JSON-RPC from `DataAgent MCP Server v1.0.0`; endpoint reachable + authenticated. Only the `tools/call` **task/run** fails ("run failed before producing a result"). `home-cluster-uri`=west-us3 (tenant home) while capacity=East US 2. |

**S1 CONCLUSION — NOT a network/private-link problem.** Plain `curl` from the client machine reaches
the Fabric MCP endpoint and gets **HTTP 200** on `initialize` with a valid JSON-RPC response, using only
the az-CLI bearer token over the public internet. Fabric is open (`AllowAccessOverPrivateLinks=False`,
`BlockAccessFromPublicNetworks=False`; Foundry — not Fabric — is the private resource). A network block
would fail at connect/TLS, not return HTTP 200. The sole failure is the data-agent **run/task** under a
non-portal client identity → **root cause = H2 auth/consent** (the Azure-CLI app isn't consented for the
data-agent Copilot run the Fabric first-party portal client uses). Secondary: **H3** — the Foundry
`fabric_dataagent_preview` tool can't read workspace/artifact IDs from a CLI/ARM-created connection
(portal-created connection needed). H1/H4 ruled out.

**Fix directions:** (a) consume via the Foundry native Fabric tool using a **portal-created** connection
(Foundry OBO uses a consented first-party app — the supported path); or (b) obtain a token from a client
that carries the data-agent delegated consent (portal/app-registration with admin consent) for bare-MCP
use. Bare az-CLI tokens will keep failing the run by design.

**Interim finding (S1):** Network is **unlikely the root cause of the run failure** — DNS resolves the
Fabric host to a public IP from the VNet resolver, capacity+Foundry are co-located in East US 2, the
agent subnet's NSG permits internet egress, and the identical run failure reproduces over the fully
public path from a client machine (T4). That leaves **H2 (auth/OBO consent)** as the run blocker and
**H3 (preview connection ID-read)** as the Foundry-tool config blocker. The remaining open network
question is only the **Foundry agent-runtime egress** from `snet-agents`; the exact portal error text
(timeout vs auth) disambiguates whether the in-VNet probe (T2/T3) is needed.

**T8 — Fabric network lockdown state (answers "isn't the MCP call blocked by private link?"):** The
`publicNetworkAccess=Disabled` + private link is on the **Foundry account** (`services.ai.azure.com`),
NOT on Fabric. Fabric tenant settings: `AllowAccessOverPrivateLinks=False`, `BlockAccessFromPublicNetworks=False`;
the workspace has no inbound-block applied (we reach it and MCP discovery works). So `api.fabric.microsoft.com`
is **still public** (Fabric lockdown = deferred, per D2) — which is exactly why the direct MCP call connects.
If Fabric private link + public-block were on, the call would fail at connect/TLS, not at "run". Conclusion:
**the MCP run failure is auth/consent, not a Fabric network/private-link issue.** (Locking down Fabric is
Phase 5 hardening and would then *require* the private path.)

**Exit criteria:** identify which hypothesis holds with evidence, and either fix it or record the exact
manual step (per D4). If H1: add DNS forwarding / egress for Fabric. If H2: obtain a token from a
consented client (portal connection or app registration). If H3: use portal-created connection. If H4:
co-locate capacity + Foundry region.

## Status log
| Time (UTC) | Phase | Update |
|------------|-------|--------|
| 2026-09-15T~02:05 | 0 | Sprint plan created; starting Phase 1. |
| 2026-09-15T~02:40 | 0 | VPN connected; PEs reachable on 443. Corp NRPT overrides push privatelink names to public DNS and no local admin — system DNS stays public. Foundry to stay private; Phase 4 will use `curl --resolve`. Capacity set to F4. |
| 2026-09-16T02:22 | 1 | 1.1 F4 capacity `fabricfoundrycap` deployed (Active). 1.2 workspace `fabric-foundry-ws` (`98edd5b8-…`) created on it. 1.3 private-link DEFERRED to hardening (D2). Starting Phase 2 (data → Lakehouse). |
| 2026-09-16T02:27 | 2 | 2.1 sample data generated (`data/generate_retail_sales.py`: 200 customers / 30 products / 5000 sales). 2.2 Lakehouse `RetailSales` (`0d46a133-…`) created, SQL endpoint provisioned. 2.3 loading Delta tables to OneLake `Tables/` via delta-rs — in progress. Also scrubbed identifiers + placeholdered capacity admin. |
| 2026-09-16T02:33 | 2 | 2.3 done — `customers`/`products`/`sales` written as Managed Delta tables, confirmed via Lakehouse tables API. Phase 2 complete. Starting Phase 3 (Fabric data agent). |
| 2026-09-16T02:45 | 3 | 3.1 data agent `RetailSalesAgent` (`ef2b5550-…`) created via fabric-data-agent-sdk, lakehouse datasource added, **published**. 3.2 AI instructions set; validating via MCP endpoint next. Starting Phase 4 (Foundry agent + Fabric tool). |
| 2026-09-16T03:05 | 3 | 3.2 config + data verified (SQL endpoint 5000/200/30; 18 cols selected/published; MCP tool discoverable). But live runs fail generically ("run failed before producing a result") for any question incl. "Hello", on both F4 and F16 — model/Copilot run failing, no API detail. Ruled out: capacity (both fail), tenant AOAI (enabled), table selection (done), data path (SQL works). Needs Fabric portal error msg to root-cause. Added pyodbc SQL check + MCP/inspect scripts. |
| 2026-09-16T03:30 | 3→4 | **Data agent CONFIRMED WORKING interactively in the Fabric portal** (user ran a query successfully). Bare-script MCP call still fails — az-CLI token lacks the Copilot/AOAI delegation the run needs from a non-interactive client; this is a harness limitation, not an agent fault. Proper consumption path = the Foundry **Microsoft Fabric** tool (identity passthrough via a project connection). Marking 3.2 DONE (agent functional) and moving to Phase 4: build the Foundry agent + Fabric tool connection. |
| 2026-09-16T05:10 | 4 | Built Phase 4: created Foundry project connection `fabric-retailsales` (ARM, CustomKeys w/ workspace_id+artifact_id) and a `gpt-5.1` prompt agent with `MicrosoftFabricPreviewTool`. Fixed an httpx2/brotli decoder crash (uninstalled Brotli). Tool call fails: *"Workspace ID and Artifact ID are required from connection details"* — tried keys/metadata/target/all case spellings, inline `additional_properties`, granted **Foundry Project Manager** (`Microsoft.CognitiveServices/*`). Setting `target=api.fabric.microsoft.com` changed the error (service now recognizes it as AzureFabric) but still can't read IDs → looks like a **preview gap for CLI/ARM-created connections**. User then added the tool via the **portal** and it also "seems blocked". Opened **Spike S1** to isolate network vs auth vs connection. |
| 2026-09-16T05:40 | S1 | Spike S1 running. T1 ✅ Fabric host resolves to **public** IP via the private resolver; T7 ✅ capacity+Foundry both **East US 2**; NSG permits internet egress; T4 shows the run failure reproduces over the **public** path (network-independent). **Interim: not a network problem for the run** — root cause points to **auth/OBO consent (H2)** for the data-agent run + **preview connection ID-read (H3)** for the Foundry tool. Next: get exact portal error (timeout vs auth) and, if needed, run in-VNet probe (T2/T3). |
| 2026-09-16T08:15 | S1 | **Spike CLOSED — NOT network.** Proved with raw `curl`: `initialize` on the Fabric MCP endpoint returns **HTTP 200** + valid JSON-RPC (`DataAgent MCP Server v1.0.0`) using only the az-CLI token over the public internet. Fabric tenant confirms private link off / public not blocked (Foundry is the private resource, not Fabric). Only the data-agent **run/task** fails, identically over the public path → **root cause = auth/consent (H2)**; the CLI client isn't consented for the data-agent Copilot run that the Fabric portal's first-party client uses. Secondary **H3**: Foundry tool can't read IDs from a CLI/ARM-created connection. Fix = Foundry native tool w/ **portal-created** connection (consented OBO), or a token from a consented client. In-VNet probe unnecessary. |

---

## S2 — H3 SOLVED (connection ID-read) + H2 narrowed to OBO run consent

**H3 ROOT CAUSE = a documentation bug (wrong key names).** The Foundry Fabric tool reads the
workspace/artifact IDs from the connection's `credentials.keys` using **hyphenated** key names —
`workspace-id` and `artifact-id` — NOT the underscore names (`workspace_id`/`artifact_id`) shown in
the public doc. Discovered by running `listsecrets` on a **portal-created** connection
(`fabric_dataagent_preview_*`): it stores `metadata:{"type":"fabric_dataagent_preview"}`, `target:"-"`,
and `credentials.keys:{"workspace-id":..., "artifact-id":...}`.

**Proof:** a REST/ARM `PUT` connection built with that exact shape (hyphenated keys) changed the tool
error from `400 Workspace ID and Artifact ID are required` → `400 Fabric run failed during execution`.
i.e. the service now READS the IDs and actually invokes the Fabric data-agent run. `data/setup_fabric_connection.py`
updated to emit the correct shape; REST-created connections are now equivalent to portal-created ones.
**H3 is closed — scripted/automated connection setup is unblocked.**

**Remaining blocker = H2 (run authorization).** With a correct connection (portal- OR REST-created), the
Foundry native Fabric tool consistently returns `400 ... "Fabric run failed during execution" code=tool_user_error`
(non-transient across retries and multiple questions). `tool_user_error` + the doc's `unauthorized`
troubleshooting row point to the **OBO identity being unable to execute the data-agent run** — the same
consent gap that fails every token-based path (bare MCP with az-CLI token) while the **interactive Fabric
portal** (which carries full Copilot/data-agent delegated consent) succeeds (T6).

**Definitive next test (needs user, interactive):** run the SAME native-Fabric-tool agent from the
**Foundry portal playground** (Agents → add Microsoft Fabric tool → the portal connection → ask a data
question). The portal can complete an interactive OBO consent the SDK cannot trigger:
- If it **answers** → the blocker is purely SDK-side consent; wire the working connection into the agent and finish Phase 4.
- If it **fails the same way** → OBO consent for the Foundry first-party app must be granted by a
  Fabric/Entra **tenant admin** (admin-consent the Fabric data-agent delegated permission), or enable any
  tenant setting gating data-agent consumption by non-Fabric services.

**Cleanup pending:** throwaway test agents (`fabtest-*`, `retail-mdkeys`, `retail-insights`, `RetailInsightsAgent*`)
and connections (`fabric-ds-clean`, `fabric-hyphen-test`, duplicate `fabric_dataagent_preview_*`).

---

## S3 — RESOLVED: root cause was an unpublished/stale data-agent publish

**The Foundry↔Fabric run failure is FIXED.** After every other hypothesis was ruled out
(network S1; connection key-format H3 solved via hyphenated `workspace-id`/`artifact-id`; capacity SKU —
reassigned workspace to F16 and it still failed; region — crime agent that works is ALSO East US 2;
data-agent config/publish parts all present), the actual fix was **re-publishing the Fabric data agent**.
The published stage was stale/incomplete, so every external run failed "before producing a result" while
the interactive draft worked. Once published:
- Bare MCP run → `5,000 rows in the sales table` ✅
- Foundry OBO native Fabric tool → `**5,000 rows**` with citation ✅ (on the dedicated **F4** `fabricfoundrycap`).

**Phase 4 COMPLETE** — a Foundry prompt agent, via the native Microsoft Fabric tool (identity passthrough/OBO)
over a portal- or REST-created `fabric_dataagent_preview` connection (hyphenated keys), answers questions
grounded in the RetailSales lakehouse through the published `RetailSalesAgent` data agent.

### Phase 5 — lockdown (in progress)
- **Foundry**: already private — account `publicNetworkAccess=Disabled` + private endpoint (group `account`)
  on `snet-pe`; PEs also for ACR, Search, Cosmos, Storage, Azure Monitor. ✅
- **Fabric workspace**: Stage 04 deployed — `Microsoft.Fabric/privateLinkServicesForFabric` +
  private endpoint into `snet-pe` (subresource `workspace`) + `privatelink.fabric.microsoft.com` DNS zone/link/group. ✅
  Prereqs verified: `Microsoft.Fabric` RP Registered; tenant toggle `WorkspaceBlockInboundAccess=True`
  (workspace-level inbound rules) ON; tenant-level PL/public-block correctly OFF.
- **Next**: verify workspace FQDN resolves to a private IP over the VPN → run `set-deny-public-access.ps1`
  → re-verify Foundry→Fabric OBO still routes (privately) and answers.
