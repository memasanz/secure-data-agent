<#
    Fetches the upstream Microsoft Foundry "private network standard agent setup" Bicep sample
    into ./sample so it can be deployed as Stage 03 (the Foundry + BYO + private endpoint core).

    We reuse the upstream sample rather than re-implementing its fragile capability-host logic
    (it encodes numerous 409 / ordering gotchas). Stages 01 and 02 provide the VNet and the
    inbound access path (VPN + DNS resolver) that the sample does not.

    Usage:  ./get-foundry-sample.ps1
#>

$ErrorActionPreference = 'Stop'

$repo    = 'https://github.com/microsoft-foundry/foundry-samples.git'
$subPath = 'infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup'
$dest    = Join-Path $PSScriptRoot 'sample'

if (Test-Path $dest) {
    Write-Host "Sample already present at $dest. Delete it to re-fetch." -ForegroundColor Yellow
    return
}

$tmp = Join-Path $env:TEMP ("foundry-samples-" + [guid]::NewGuid().ToString('N'))
git clone --depth 1 --filter=blob:none --sparse $repo $tmp
Push-Location $tmp
try {
    git sparse-checkout set $subPath
} finally {
    Pop-Location
}

Copy-Item -Recurse -Force (Join-Path $tmp $subPath) $dest
Remove-Item -Recurse -Force $tmp

Write-Host "Foundry sample fetched to $dest" -ForegroundColor Green
Write-Host "Next: review $dest/README.md, then deploy with foundry.parameters.example.json (see infra/README.md)." -ForegroundColor Cyan
