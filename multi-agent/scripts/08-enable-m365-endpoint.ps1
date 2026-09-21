#requires -Version 7.0
<#
.SYNOPSIS
  Pin the orchestrator version that carries the A2A tools and enable the M365 public endpoint.
.DESCRIPTION
  WARNING: this PATCH REPLACES protocol_configuration and authorization_schemes wholesale.
  Anything you omit is dropped - including "responses" and "Entra".

  Pin the version explicitly. It is easy to enable the endpoint against an older version
  that has no A2A tools and then wonder why Teams never delegates.
#>
param(
    [Parameter(Mandatory)][string] $Version,
    [ValidateSet("BotServiceRbac","BotServiceTenant")][string] $BotAuthScheme = "BotServiceRbac"
)
. "$PSScriptRoot/00-variables.ps1"

$body = @{
    agent_endpoint = @{
        protocol_configuration = @{
            responses = @{}
            activity  = @{ enable_m365_public_endpoint = $true }
        }
        authorization_schemes = @(
            @{ type = "Entra" }
            @{ type = $BotAuthScheme }
        )
        version_selector = @{
            version_selection_rules = @(
                @{ type = "FixedRatio"; agent_version = $Version; traffic_percentage = 100 }
            )
        }
    }
} | ConvertTo-Json -Depth 8

Write-Host "Pinning $OrchestratorName to v$Version and enabling the M365 public endpoint ..." -ForegroundColor Cyan
$r = Invoke-RestMethod -Method Patch -Uri "$ProjectEndpoint/agents/$OrchestratorName`?api-version=v1" `
        -Headers (Get-FoundryHeaders "application/merge-patch+json") -Body $body
$r.agent_endpoint | ConvertTo-Json -Depth 8
