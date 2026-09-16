#requires -Version 7.0
<#
.SYNOPSIS
  Enable the source-IP-filtered Activity Protocol public endpoint. This is the setting that
  replaces the APIM / App Gateway / proxy-container-app chain.

.DESCRIPTION
  WARNING: this PATCH REPLACES protocol_configuration and authorization_schemes wholesale.
  Every protocol and authorization scheme the endpoint must retain has to be present in the
  body below. Anything omitted is dropped - including "responses" and "Entra".

  Choose the authorization scheme that matches the publishScope used in step 05:
    Shared / Personal -> BotServiceRbac
    Tenant            -> BotServiceTenant
#>
param(
    [ValidateSet("BotServiceRbac", "BotServiceTenant")]
    [string]$BotAuthScheme = "BotServiceRbac",

    [switch]$PinVersion,
    [string]$Version = "1"
)
. "$PSScriptRoot/00-variables.ps1"

$endpointConfig = @{
    protocol_configuration = @{
        responses = @{}
        activity  = @{ enable_m365_public_endpoint = $true }
    }
    authorization_schemes = @(
        @{ type = "Entra" }
        @{ type = $BotAuthScheme }
    )
}

if ($PinVersion) {
    $endpointConfig.version_selector = @{
        version_selection_rules = @(
            @{ type = "FixedRatio"; agent_version = $Version; traffic_percentage = 100 }
        )
    }
}

$body = @{ agent_endpoint = $endpointConfig } | ConvertTo-Json -Depth 8

Write-Host "Enabling enable_m365_public_endpoint on $AgentName ..." -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest -UseBasicParsing `
        -Uri "$ProjectEndpoint/agents/$AgentName`?api-version=v1" `
        -Headers (Get-FoundryHeaders "application/merge-patch+json") `
        -Method Patch -Body $body

    ($r.Content | ConvertFrom-Json).agent_endpoint | ConvertTo-Json -Depth 8
    Write-Host "Done." -ForegroundColor Green
}
catch {
    Write-Error "Failed ($($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)"
}
