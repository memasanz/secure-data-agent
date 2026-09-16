<#
    Sets the Microsoft Fabric workspace inbound communication policy to DENY public
    access, so the workspace is reachable ONLY over the workspace-level private link.

    This is the REST-API equivalent of Stage 04 step 7 (the deny-public-access step
    is NOT ARM-deployable). See:
    https://learn.microsoft.com/fabric/security/security-workspace-level-private-links-set-up?tabs=api

    PREREQUISITES (do NOT run this before they are true, or you can lock yourself out):
      - Stage 04 deployed: the Fabric private endpoint into snet-pe exists and is approved.
      - You have verified private resolution over the P2S VPN
        (nslookup {workspaceid}.z{xy}.w.api.fabric.microsoft.com -> private IP).
      - You are a workspace admin.

    Usage:
      ./set-deny-public-access.ps1 -WorkspaceId <guid>
      ./set-deny-public-access.ps1 -WorkspaceId <guid> -Action Allow   # revert
      ./set-deny-public-access.ps1 -WorkspaceId <guid> -WhatIf         # show only
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [ValidateSet('Deny', 'Allow')]
    [string]$Action = 'Deny'
)

$ErrorActionPreference = 'Stop'

$fabricResource = 'https://api.fabric.microsoft.com'
$baseUri = "$fabricResource/v1/workspaces/$WorkspaceId/networking/communicationPolicy"

Write-Host "Acquiring Fabric API token..." -ForegroundColor Cyan
$token = az account get-access-token --resource $fabricResource --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire an access token for $fabricResource. Run 'az login' first." }
$headers = @{ Authorization = "Bearer $token" }

Write-Host "Current inbound communication policy:" -ForegroundColor Cyan
try {
    $current = Invoke-RestMethod -Method Get -Uri $baseUri -Headers $headers
    $current | ConvertTo-Json -Depth 10 | Write-Host
} catch {
    Write-Host "  (none set yet or not readable: $($_.Exception.Message))" -ForegroundColor Yellow
}

$body = @{
    inbound = @{
        publicAccessRules = @{
            defaultAction = $Action
        }
    }
} | ConvertTo-Json -Depth 10

if ($PSCmdlet.ShouldProcess("workspace $WorkspaceId", "set inbound public access defaultAction = $Action")) {
    Write-Host "Setting inbound public access defaultAction = $Action ..." -ForegroundColor Cyan
    Invoke-RestMethod -Method Put -Uri $baseUri -Headers $headers -ContentType 'application/json' -Body $body | Out-Null

    Write-Host "Done. New policy:" -ForegroundColor Green
    Invoke-RestMethod -Method Get -Uri $baseUri -Headers $headers | ConvertTo-Json -Depth 10 | Write-Host
    if ($Action -eq 'Deny') {
        Write-Host "NOTE: The deny-public-access change can take up to ~30 minutes to take effect." -ForegroundColor Yellow
    }
}
