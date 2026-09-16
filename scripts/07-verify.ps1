#requires -Version 7.0
<#
.SYNOPSIS
  Verify reachability. Run the same script from the public internet and from inside the VNet.

.DESCRIPTION
  Expected results when public network access is DISABLED:

    Location            GET /agents/{name}   POST .../responses   DNS
    public internet     403                  403                  public CNAME chain
    inside the VNet     200                  200                  -> privatelink -> PE IP

  Teams keeps working in both cases - that is the whole point of the pattern.
#>
. "$PSScriptRoot/00-variables.ps1"

$fqdn = "$AccountName.services.ai.azure.com"

Write-Host "=== DNS resolution ===" -ForegroundColor Cyan
Resolve-DnsName $fqdn -ErrorAction SilentlyContinue |
    Select-Object Name, Type, IPAddress, NameHost | Format-Table -AutoSize

Write-Host "=== TCP 443 ===" -ForegroundColor Cyan
$t = Test-NetConnection -ComputerName $fqdn -Port 443 -WarningAction SilentlyContinue
"RemoteAddress = $($t.RemoteAddress)   TcpTestSucceeded = $($t.TcpTestSucceeded)"

$headers = Get-FoundryHeaders

Write-Host "`n=== GET agent (management API) ===" -ForegroundColor Cyan
try {
    $a = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 40 `
        -Uri "$ProjectEndpoint/agents/$AgentName`?api-version=v1" `
        -Headers $headers -Method GET).Content | ConvertFrom-Json
    Write-Host "200 OK  m365public=$($a.agent_endpoint.protocol_configuration.activity.enable_m365_public_endpoint)  protocols=$($a.agent_endpoint.protocols -join ',')" -ForegroundColor Green
}
catch { Write-Host "BLOCKED -> $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Yellow }

Write-Host "`n=== POST responses (inference) ===" -ForegroundColor Cyan
try {
    $body = @{ input = "In one sentence, how does Teams reach you?" } | ConvertTo-Json
    $r = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 90 `
        -Uri "$ProjectEndpoint/agents/$AgentName/endpoint/protocols/openai/responses?api-version=v1" `
        -Headers $headers -Method POST -Body $body).Content | ConvertFrom-Json
    Write-Host "200 OK -> $(($r.output | ForEach-Object { $_.content.text }) -join ' ')" -ForegroundColor Green
}
catch { Write-Host "BLOCKED -> $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Yellow }
