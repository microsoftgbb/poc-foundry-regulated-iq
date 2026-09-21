#requires -Version 7.0
<#
.SYNOPSIS
  Grant the agent identities the roles required for agent-to-agent calls.
.DESCRIPTION
  THIS IS THE STEP PEOPLE MISS.

  Before publishing, every agent in a project shares one identity.
  After publishing, the published agent receives its OWN new identity - and that new
  identity has no role assignments. Every A2A call then fails with:

      Failed to fetch agent card: 404 (Not Found)
      The target A2A agent card was not found or is not accessible to the configured identity.

  Re-run this script after publishing, using the identity printed by 06-show-identity.ps1.
#>
param(
    [Parameter(Mandatory)][string[]] $PrincipalId
)
. "$PSScriptRoot/00-variables.ps1"

foreach ($id in $PrincipalId) {
    foreach ($role in @("Foundry User", "Foundry Agent Consumer")) {
        Write-Host "Assigning '$role' to $id ..." -ForegroundColor Cyan
        az role assignment create `
            --assignee-object-id $id `
            --assignee-principal-type ServicePrincipal `
            --role "$role" `
            --scope $ProjectScope `
            --only-show-errors | Out-Null
    }
    Write-Host "Roles now on ${id}:" -ForegroundColor Green
    az role assignment list --assignee-object-id $id --scope $ProjectScope --query "[].roleDefinitionName" -o tsv
}

Write-Host ""
Write-Host "Allow 2-3 minutes for RBAC to propagate before invoking the orchestrator." -ForegroundColor Yellow
