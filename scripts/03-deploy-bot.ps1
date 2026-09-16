#requires -Version 7.0
<#
.SYNOPSIS
  Deploy the Azure Bot Service resource and connect the Microsoft Teams channel.
.PARAMETER MsaAppId
  The agent identity client_id from 02-get-agent-identity.ps1.
#>
param(
    [Parameter(Mandatory)][string]$MsaAppId
)
. "$PSScriptRoot/00-variables.ps1"

$activityEndpoint = "$ProjectEndpoint/agents/$AgentName/endpoint/protocols/activityProtocol?api-version=2025-05-15-preview"

Write-Host "Deploying Bot Service: $BotName" -ForegroundColor Cyan
$result = az deployment group create `
    --resource-group $ResourceGroup `
    --name botdeploy `
    --template-file "$PSScriptRoot/../infra/bot-service.json" `
    --parameters botName=$BotName `
                 displayName="$BotDisplayName" `
                 msaAppId=$MsaAppId `
                 tenantId=$TenantId `
                 endpoint=$activityEndpoint `
    --query "{state:properties.provisioningState, botId:properties.outputs.botServiceArmId.value}" `
    -o json | ConvertFrom-Json

Write-Host "State:  $($result.state)" -ForegroundColor Green
Write-Host "Bot ARM ID (pass as botServiceArmId in step 05):"
Write-Host $result.botId
