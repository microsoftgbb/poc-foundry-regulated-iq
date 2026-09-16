#requires -Version 7.0
<#
.SYNOPSIS
  Get the agent's identity client_id - needed as msaAppId for the Bot Service resource.
.NOTES
  Use instance_identity.client_id. The principal_id is not used in this flow.
#>
. "$PSScriptRoot/00-variables.ps1"

try {
    $a = (Invoke-WebRequest -UseBasicParsing `
        -Uri "$ProjectEndpoint/agents/$AgentName`?api-version=v1" `
        -Headers (Get-FoundryHeaders) -Method GET).Content | ConvertFrom-Json

    [pscustomobject]@{
        Agent             = $a.name
        ClientId          = $a.instance_identity.client_id
        Protocols         = ($a.agent_endpoint.protocols -join ", ")
        M365PublicEndpoint= $a.agent_endpoint.protocol_configuration.activity.enable_m365_public_endpoint
        AuthSchemes       = ($a.agent_endpoint.authorization_schemes.type -join ", ")
        PublishStatus     = $a.agent_endpoint.publish_approval_status
    } | Format-List

    Write-Host "Activity Protocol endpoint (use as the Bot Service endpoint):" -ForegroundColor Cyan
    Write-Host "$ProjectEndpoint/agents/$AgentName/endpoint/protocols/activityProtocol?api-version=2025-05-15-preview"
}
catch {
    Write-Error "Failed ($($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)"
}
