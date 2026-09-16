#requires -Version 7.0
<#
.SYNOPSIS
  Create the Foundry agent and its first version.
.DESCRIPTION
  POST /agents/{name}/versions requires the agent body wrapped in a "definition" object.
  Run from a client that can reach the project's private endpoint if PNA is disabled.
#>
. "$PSScriptRoot/00-variables.ps1"

$instructions = @"
You are the Contoso Private Network Helpdesk agent. You run inside an Azure virtual network
with public network access disabled on the Foundry account. Answer concisely.
When asked how you are connected, explain that Teams reaches you through the Foundry-managed
Activity Protocol public endpoint with service-managed source IP filtering, with no APIM or
proxy in the path.
"@

$body = @{
    definition = @{
        kind         = "prompt"
        model        = $ModelName
        instructions = $instructions
    }
    description = "Private-networked Foundry agent published to Teams without APIM."
} | ConvertTo-Json -Depth 6

Write-Host "Creating agent version: $AgentName" -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest -UseBasicParsing `
        -Uri "$ProjectEndpoint/agents/$AgentName/versions?api-version=v1" `
        -Headers (Get-FoundryHeaders) -Method POST -Body $body
    $v = $r.Content | ConvertFrom-Json
    Write-Host "Created $($v.id)" -ForegroundColor Green
    Write-Host "instance_identity.client_id = $($v.instance_identity.client_id)"
}
catch {
    Write-Error "Failed ($($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)"
}
