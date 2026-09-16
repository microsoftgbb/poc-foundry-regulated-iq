#requires -Version 7.0
<#
.SYNOPSIS
  Publish the agent to Microsoft 365 Copilot and Microsoft Teams.
.PARAMETER BotServiceArmId
  ARM resource ID of the Bot Service resource created in step 03.
.NOTES
  publishScope Shared / Personal -> BotServiceRbac, no admin approval, visible only to you.
  publishScope Tenant            -> BotServiceTenant, requires M365 admin center approval.
  Republishing the same appVersion returns "version already exists" - increment it.
  Never put secrets in the metadata fields; they are visible to users.
#>
param(
    [Parameter(Mandatory)][string]$BotServiceArmId
)
. "$PSScriptRoot/00-variables.ps1"

$body = @{
    agentDisplayName    = $BotDisplayName
    botServiceArmId     = $BotServiceArmId
    publishScope        = $PublishScope
    publishAsAutopilot  = $false
    appVersion          = $AppVersion
    shortDescription    = "Private-networked Foundry agent in Teams"
    fullDescription     = "A Foundry agent running behind a private endpoint with public network access disabled, published to Microsoft 365 and Teams via the Foundry-managed Activity Protocol endpoint. No APIM or proxy in the path."
    developerName       = "Contoso"
    developerWebsiteUrl = "https://azure.microsoft.com"
    privacyUrl          = "https://privacy.microsoft.com"
    termsOfUseUrl       = "https://www.microsoft.com/legal/terms-of-use"
} | ConvertTo-Json -Depth 5

Write-Host "Publishing $AgentName to Microsoft 365 (scope: $PublishScope) ..." -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest -UseBasicParsing `
        -Uri "$ProjectEndpoint/agents/$AgentName/microsoft365/publish?api-version=v1" `
        -Headers (Get-FoundryHeaders) -Method POST -Body $body

    $out = $r.Content | ConvertFrom-Json
    Write-Host "Published." -ForegroundColor Green
    Write-Host "titleId:    $($out.titleId)"
    Write-Host "teamsAppId: $($out.teamsAppId)"
}
catch {
    Write-Error "Failed ($($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)"
}
