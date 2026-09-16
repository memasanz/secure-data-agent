<#
    verify-agent-rbac.ps1

    Confirms that the Azure AI Foundry *project* managed identity holds the RBAC that the
    Foundry Agent Service (Standard/BYO setup) needs on its dependent resources. The upstream
    Stage 03 sample assigns these automatically; this script is a read-only verification you can
    run after deployment (or when diagnosing agent 401/403s against Storage/Search/Cosmos).

    Checks (all against the PROJECT managed identity, not the account identity):
      Azure AI Search   -> Search Index Data Contributor, Search Service Contributor   (ARM)
      Storage account   -> Storage Blob Data Contributor, Storage Blob Data Owner      (ARM)
      Cosmos DB account -> Cosmos DB Operator                                          (ARM)
      Cosmos DB (data)  -> Cosmos DB Built-in Data Contributor                         (SQL role)

    Usage:
      ./verify-agent-rbac.ps1                                   # uses the defaults below
      ./verify-agent-rbac.ps1 -ResourceGroup rg -AccountName acc -ProjectName proj

    Read-only: it performs no writes. Exits 0 if all required roles are present, else 1.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-fabric-foundry-eus2',
    [string]$AccountName   = 'ffndryfsnn',
    [string]$ProjectName   = 'fabricagentfsnn',
    [string]$ApiVersion    = '2025-04-01-preview'
)

$ErrorActionPreference = 'Stop'

function Write-Result($ok, $text) {
    if ($ok) { Write-Host ("  [PASS] " + $text) -ForegroundColor Green }
    else     { Write-Host ("  [FAIL] " + $text) -ForegroundColor Red }
}

# --- Resolve the project managed identity principal ID ---------------------------------
$sub = az account show --query id -o tsv
$projUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/$ProjectName`?api-version=$ApiVersion"
$project = az rest --method get --uri $projUri | ConvertFrom-Json
$principalId = $project.identity.principalId
if (-not $principalId) { throw "Could not resolve the project managed identity principalId for $AccountName/$ProjectName." }
Write-Host "Project managed identity principalId: $principalId" -ForegroundColor Cyan

# --- Pull all ARM role assignments for that principal ----------------------------------
$assignments = az role assignment list --assignee $principalId --all -o json | ConvertFrom-Json

# Helper: is a given role present on a scope whose resource type matches $typeMatch?
function Has-Role($roleName, $typeMatch) {
    foreach ($a in $assignments) {
        if ($a.roleDefinitionName -eq $roleName -and $a.scope -like "*$typeMatch*") { return $true }
    }
    return $false
}

$failures = 0
$checks = @(
    @{ Role = 'Search Index Data Contributor'; Type = '/Microsoft.Search/searchServices/';        Resource = 'AI Search'  },
    @{ Role = 'Search Service Contributor';     Type = '/Microsoft.Search/searchServices/';        Resource = 'AI Search'  },
    @{ Role = 'Storage Blob Data Contributor';  Type = '/Microsoft.Storage/storageAccounts/';      Resource = 'Storage'    },
    @{ Role = 'Storage Blob Data Owner';        Type = '/Microsoft.Storage/storageAccounts/';      Resource = 'Storage'    },
    @{ Role = 'Cosmos DB Operator';             Type = '/Microsoft.DocumentDB/databaseAccounts/';  Resource = 'Cosmos DB'  }
)

Write-Host "`nARM role assignments:" -ForegroundColor Cyan
foreach ($c in $checks) {
    $ok = Has-Role $c.Role $c.Type
    Write-Result $ok ("{0} on {1}" -f $c.Role, $c.Resource)
    if (-not $ok) { $failures++ }
}

# --- Cosmos DB data-plane (SQL) role assignment ----------------------------------------
# Built-in role "Cosmos DB Built-in Data Contributor" == sqlRoleDefinitions/...-002
Write-Host "`nCosmos DB data-plane (SQL) role:" -ForegroundColor Cyan
$cosmos = az resource list -g $ResourceGroup --resource-type 'Microsoft.DocumentDB/databaseAccounts' --query "[0].name" -o tsv
if (-not $cosmos) {
    Write-Result $false "No Cosmos DB account found in $ResourceGroup to check"
    $failures++
} else {
    $sqlAssignments = az cosmosdb sql role assignment list -g $ResourceGroup -a $cosmos -o json | ConvertFrom-Json
    $hasDataContributor = $false
    foreach ($ra in $sqlAssignments) {
        if ($ra.principalId -eq $principalId -and $ra.roleDefinitionId -like '*sqlRoleDefinitions/00000000-0000-0000-0000-000000000002*') {
            $hasDataContributor = $true
        }
    }
    Write-Result $hasDataContributor ("Cosmos DB Built-in Data Contributor on account '$cosmos'")
    if (-not $hasDataContributor) { $failures++ }
}

# --- Summary ---------------------------------------------------------------------------
Write-Host ""
if ($failures -eq 0) {
    Write-Host "All required agent RBAC assignments are present." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures required role assignment(s) missing. The Stage 03 sample normally assigns these;" -ForegroundColor Yellow
    Write-Host "re-run the sample deployment, or assign the missing roles to principal $principalId." -ForegroundColor Yellow
    exit 1
}
