<#
    Creates a Microsoft Fabric workspace via the Fabric REST API and (optionally)
    assigns it to a Fabric capacity. The returned workspace ID feeds the rest of
    Stage 04: put it into 04-fabric/main.bicepparam (workspaceId) and pass it to
    set-deny-public-access.ps1.

    API: https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace

    IMPORTANT for the private-link design:
      - Workspace-level private link REQUIRES the workspace to be on a Fabric
        capacity (F SKU). Pass -CapacityId so it is assigned at creation; P/trial
        capacities are NOT supported for private link.
      - The caller must have permission to create workspaces (granted by a Fabric
        admin) and be contributor/admin on the target capacity.

    Usage:
      ./create-workspace.ps1 -DisplayName 'fabric-foundry-ws'
      ./create-workspace.ps1 -DisplayName 'fabric-foundry-ws' -CapacityId <capacity-guid>
      ./create-workspace.ps1 -ListCapacities      # discover F-SKU capacity IDs
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Create')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
    [string]$DisplayName,

    [Parameter(ParameterSetName = 'Create')]
    [string]$CapacityId,

    [Parameter(ParameterSetName = 'Create')]
    [string]$Description = '',

    [Parameter(Mandatory = $true, ParameterSetName = 'List')]
    [switch]$ListCapacities
)

$ErrorActionPreference = 'Stop'

$fabricResource = 'https://api.fabric.microsoft.com'

Write-Host "Acquiring Fabric API token..." -ForegroundColor Cyan
$token = az account get-access-token --resource $fabricResource --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire an access token for $fabricResource. Run 'az login' first." }
$headers = @{ Authorization = "Bearer $token" }

if ($ListCapacities) {
    Write-Host "Fabric capacities visible to you:" -ForegroundColor Cyan
    $caps = Invoke-RestMethod -Method Get -Uri "$fabricResource/v1/capacities" -Headers $headers
    $caps.value | Select-Object id, displayName, sku, region, state | Format-Table -AutoSize
    Write-Host "Use an 'F' SKU capacity id with -CapacityId for private-link workspaces." -ForegroundColor Yellow
    return
}

$bodyObj = @{ displayName = $DisplayName }
if ($CapacityId)  { $bodyObj.capacityId  = $CapacityId }
if ($Description) { $bodyObj.description = $Description }
$body = $bodyObj | ConvertTo-Json -Depth 10

if ($PSCmdlet.ShouldProcess("Fabric", "create workspace '$DisplayName'")) {
    Write-Host "Creating workspace '$DisplayName'..." -ForegroundColor Cyan
    $ws = Invoke-RestMethod -Method Post -Uri "$fabricResource/v1/workspaces" -Headers $headers -ContentType 'application/json' -Body $body

    Write-Host "Created workspace:" -ForegroundColor Green
    $ws | Select-Object id, displayName, capacityId, capacityRegion, type | Format-List

    if (-not $CapacityId) {
        Write-Host "WARNING: No -CapacityId supplied. Assign the workspace to an F-SKU capacity before" -ForegroundColor Yellow
        Write-Host "         setting up workspace-level private link (Workspace settings -> License info)." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Set workspaceId = '$($ws.id)' in infra/04-fabric/main.bicepparam" -ForegroundColor Gray
    Write-Host "  2. Deploy Stage 04 (private link + PE + DNS)" -ForegroundColor Gray
    Write-Host "  3. Verify over VPN, then run set-deny-public-access.ps1 -WorkspaceId $($ws.id)" -ForegroundColor Gray

    # Emit the workspace ID as the sole pipeline output for scripting.
    return $ws.id
}
