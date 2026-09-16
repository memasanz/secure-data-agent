<#
    Adds (or removes) Windows hosts-file overrides so a corp-managed machine can
    reach the private endpoints over the P2S VPN in the browser / SDKs.

    WHY: On a corp-managed device, NRPT policies force names like
    *.cognitiveservices.azure.com, *.services.ai.azure.com and *.search.windows.net
    to corporate DNS, which returns the PUBLIC IPs. With publicNetworkAccess=Disabled
    those public IPs are unreachable, so the Foundry portal shows "Private network
    access required". The DNS Private Resolver over the VPN resolves correctly, but the
    corp NRPT rules win. The hosts file takes precedence over NRPT/DNS, so mapping the
    exact FQDNs to their private-endpoint IPs unblocks the portal WITHOUT re-enabling
    public access.

    HOW: Reads the private DNS zones in the resource group (zones named
    'privatelink.<suffix>'), turns each A record into '<privateIP> <record>.<suffix>',
    and writes them into the hosts file inside a clearly marked block. Requires admin
    (self-elevates). Requires the VPN connected to actually route to the IPs.

    Usage (run from a normal shell; it will prompt for elevation):
      ./set-hosts-overrides.ps1                 # add/refresh overrides
      ./set-hosts-overrides.ps1 -Remove         # remove the managed block
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-fabric-foundry-eus2',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$beginMarker = '# BEGIN fabric-foundry private-endpoint overrides'
$endMarker   = '# END fabric-foundry private-endpoint overrides'
$hostsPath   = "$env:windir\System32\drivers\etc\hosts"

function Test-Admin {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Build the desired entries BEFORE elevating (az context lives in the user profile). ---
$entries = @()
if (-not $Remove) {
    Write-Host "Reading private DNS zones from '$ResourceGroup'..." -ForegroundColor Cyan
    $zones = az network private-dns zone list -g $ResourceGroup --query "[?starts_with(name, 'privatelink.')].name" -o tsv
    if (-not $zones) { throw "No 'privatelink.*' private DNS zones found in $ResourceGroup. Are you logged in (az login) and on the right subscription?" }
    foreach ($zone in $zones) {
        $suffix = $zone -replace '^privatelink\.', ''
        $records = az network private-dns record-set a list -g $ResourceGroup -z $zone --query "[?aRecords].{name:name, ip:aRecords[0].ipv4Address}" -o json | ConvertFrom-Json
        foreach ($r in $records) {
            if ($r.name -eq '@' -or -not $r.ip) { continue }
            $entries += "{0}`t{1}.{2}" -f $r.ip, $r.name, $suffix
        }
    }
    if (-not $entries) { throw "No A records found in the private DNS zones. Deploy the private endpoints first." }
    Write-Host "Prepared $($entries.Count) host override(s):" -ForegroundColor Green
    $entries | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}

# --- Elevate if needed, carrying the computed entries into the admin process. ---
if (-not (Test-Admin)) {
    Write-Host "Elevation required to edit the hosts file. Launching an elevated PowerShell..." -ForegroundColor Yellow
    $payload = ($entries -join "`n")
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $inner = @"
`$ErrorActionPreference='Stop'
`$hostsPath='$hostsPath'
`$beginMarker='$beginMarker'
`$endMarker='$endMarker'
`$entries = if ('$b64') { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')) -split "`n" | Where-Object { `$_ } } else { @() }
`$content = Get-Content -LiteralPath `$hostsPath -Raw
# strip any existing managed block
`$pattern = [regex]::Escape(`$beginMarker) + '.*?' + [regex]::Escape(`$endMarker) + '\r?\n?'
`$content = [regex]::Replace(`$content, `$pattern, '', 'Singleline')
if (`$entries.Count -gt 0) {
    `$block = `$beginMarker + "``r``n" + (`$entries -join "``r``n") + "``r``n" + `$endMarker + "``r``n"
    if (`$content -and -not `$content.EndsWith("``n")) { `$content += "``r``n" }
    `$content += `$block
}
Set-Content -LiteralPath `$hostsPath -Value `$content -Encoding ASCII -NoNewline
ipconfig /flushdns | Out-Null
Write-Host 'Hosts file updated. DNS cache flushed.' -ForegroundColor Green
Start-Sleep -Seconds 2
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-EncodedCommand', $encoded -Wait
    Write-Host "Done. Verify with: Resolve-DnsName ffndryfsnn.services.ai.azure.com" -ForegroundColor Cyan
    return
}

# --- Already elevated: write directly. ---
$content = Get-Content -LiteralPath $hostsPath -Raw
$pattern = [regex]::Escape($beginMarker) + '.*?' + [regex]::Escape($endMarker) + '\r?\n?'
$content = [regex]::Replace($content, $pattern, '', 'Singleline')
if ($entries.Count -gt 0) {
    $block = $beginMarker + "`r`n" + ($entries -join "`r`n") + "`r`n" + $endMarker + "`r`n"
    if ($content -and -not $content.EndsWith("`n")) { $content += "`r`n" }
    $content += $block
}
Set-Content -LiteralPath $hostsPath -Value $content -Encoding ASCII -NoNewline
ipconfig /flushdns | Out-Null
Write-Host "Hosts file updated. DNS cache flushed." -ForegroundColor Green
