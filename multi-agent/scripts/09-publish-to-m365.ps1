#requires -Version 7.0
<#
.SYNOPSIS
  Publish the orchestrator to Microsoft Teams / Microsoft 365.
.DESCRIPTION
  Publishing needs a DELEGATED (user) token - a managed identity cannot perform the
  on-behalf-of exchange to the M365 titles service. On a network-injected account the
  call must also originate inside the VNet, so run this from the jump box after 'az login'.

  Deploy the Bot Service first (see ../../infra/bot-service.json in this repo) using the
  orchestrator's instance_identity.client_id as msaAppId.
#>
param(
    [Parameter(Mandatory)][string] $BotServiceArmId
)
. "$PSScriptRoot/00-variables.ps1"

$who = az account show --query "user.name" -o tsv 2>$null
if (-not $who) { Write-Error "Not signed in. Run 'az login' first."; exit 1 }
Write-Host "Signed in as: $who" -ForegroundColor Green

$body = @{
    agentDisplayName    = $BotDisplayName
    botServiceArmId     = $BotServiceArmId
    publishScope        = $PublishScope
    publishAsAutopilot  = $false
    appVersion          = $AppVersion
    shortDescription    = "Private-networked Foundry multi-agent orchestrator in Teams"
    fullDescription     = "An orchestrator agent that delegates over A2A to extractor, validator and approver agents. Runs behind a private endpoint with public network access disabled and reaches Teams through the Foundry-managed Activity Protocol endpoint - no APIM or proxy in the path."
    developerName       = "Contoso"
    developerWebsiteUrl = "https://azure.microsoft.com"
    privacyUrl          = "https://privacy.microsoft.com"
    termsOfUseUrl       = "https://www.microsoft.com/legal/terms-of-use"
} | ConvertTo-Json -Depth 5

Write-Host "Publishing $OrchestratorName (scope: $PublishScope) ..." -ForegroundColor Cyan
try {
    $r = Invoke-RestMethod -Method Post -Uri "$ProjectEndpoint/agents/$OrchestratorName/microsoft365/publish?api-version=v1" `
            -Headers (Get-FoundryHeaders) -Body $body
    Write-Host "Published." -ForegroundColor Green
    Write-Host "titleId:    $($r.titleId)"
    Write-Host "teamsAppId: $($r.teamsAppId)"
} catch {
    Write-Host "Publish failed:" -ForegroundColor Red
    $_.ErrorDetails.Message
}
