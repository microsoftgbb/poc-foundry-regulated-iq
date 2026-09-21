#requires -Version 7.0
<#
.SYNOPSIS
  Print the current instance identity of an agent (and its endpoint config).
.DESCRIPTION
  Use this after publishing to discover the agent's NEW identity, then feed the
  principal_id into 05-grant-agent-identity.ps1.
#>
param(
    [string] $AgentName
)
. "$PSScriptRoot/00-variables.ps1"
if (-not $AgentName) { $AgentName = $OrchestratorName }

$a = Invoke-RestMethod -Method Get -Uri "$ProjectEndpoint/agents/$AgentName`?api-version=v1" -Headers (Get-FoundryHeaders)

[pscustomobject]@{
    Agent        = $a.name
    PrincipalId  = $a.instance_identity.principal_id
    ClientId     = $a.instance_identity.client_id
    Protocols    = ($a.agent_endpoint.protocols -join ", ")
    PinnedVersion= ($a.agent_endpoint.version_selector.version_selection_rules | ForEach-Object { $_.agent_version }) -join ","
    M365Endpoint = $a.agent_endpoint.protocol_configuration.activity.enable_m365_public_endpoint
    AuthSchemes  = ($a.agent_endpoint.authorization_schemes.type -join ", ")
    PublishState = $a.agent_endpoint.publish_approval_status
} | Format-List
