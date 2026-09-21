#requires -Version 7.0
<#
.SYNOPSIS
  Create one RemoteA2A project connection per sub-agent using agentic-identity auth.
.NOTES
  Requires azd with the Foundry Connections extension (azure.ai.connections).
  The Python SDK's project.connections is read-only - it cannot create connections.

  Do NOT pass --metadata "AgentCardPath=..." for a Foundry-agent target. Foundry
  resolves its own default card path; supplying one returns
  "Agent card path is invalid for a Foundry agent".
#>
. "$PSScriptRoot/00-variables.ps1"

azd ai project set $ProjectEndpoint

foreach ($name in $SubAgents) {
    $target = "$ProjectEndpoint/agents/$name/endpoint/protocols/a2a"
    Write-Host "Creating connection conn-$name ..." -ForegroundColor Cyan
    azd ai connection create "conn-$name" `
        --kind remote-a2a `
        --target $target `
        --auth-type agentic-identity `
        --audience https://ai.azure.com `
        --force
}

Write-Host ""
azd ai connection list
