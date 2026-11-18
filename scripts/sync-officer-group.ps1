#!/usr/bin/env pwsh
# Creates the officer security group named in config/officers.json (if missing)
# and makes its membership exactly the registry's officers. Prints the group
# object ID for infra/bicep/officers.bicep. Requires an Azure CLI sign-in that can
# manage groups (for example Groups Administrator) in the Caldova tenant.
#
#   pwsh scripts/sync-officer-group.ps1            # apply
#   pwsh scripts/sync-officer-group.ps1 -WhatIf    # show changes only

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Registry = (Join-Path $PSScriptRoot '../config/officers.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tenant = '95287129-9bbb-4084-8485-dc845ae7d143'
$guid = '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'

function Invoke-Az {
    $output = & az @args --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0..2] -join ' ') failed." }
    if ($output) { return ($output | Out-String | ConvertFrom-Json -AsHashtable) }
}

$config = Get-Content -Raw -LiteralPath $Registry | ConvertFrom-Json -AsHashtable
$groupName = [string] $config.groupName
if ($groupName -notmatch '^[A-Za-z0-9 ._-]{3,64}$') { throw 'Invalid groupName in the registry.' }
$wanted = @{}
foreach ($officer in @($config.officers)) {
    if ($officer.objectId -notmatch $guid) { throw "Invalid objectId for $($officer.displayName)." }
    if ($wanted.ContainsKey($officer.objectId)) { throw "Duplicate officer $($officer.objectId)." }
    $wanted[$officer.objectId] = $officer.displayName
}

if ((Invoke-Az account show).tenantId -ne $tenant) { throw 'Azure CLI is not signed in to the Caldova tenant.' }

$found = @(Invoke-Az ad group list --filter "displayName eq '$groupName'")
if ($found.Count -gt 1) { throw "More than one group is named '$groupName'; resolve manually." }
if ($found.Count -eq 0) {
    if (-not $PSCmdlet.ShouldProcess($groupName, 'Create security group')) { return }
    $nickname = ($groupName.ToLowerInvariant() -replace '[^a-z0-9]', '')
    $group = Invoke-Az ad group create --display-name $groupName --mail-nickname $nickname `
        --description 'Case IQ officers. Membership is managed from config/officers.json.'
    Write-Output "Created group '$groupName'."
} else {
    $group = $found[0]
}

$members = @{}
foreach ($member in @(Invoke-Az ad group member list --group $group.id)) { $members[$member.id] = $true }

foreach ($id in $wanted.Keys) {
    if ($members.ContainsKey($id)) { continue }
    if ($PSCmdlet.ShouldProcess($wanted[$id], "Add to '$groupName'")) {
        Invoke-Az ad group member add --group $group.id --member-id $id | Out-Null
        Write-Output "Added $($wanted[$id])."
    }
}
foreach ($id in $members.Keys) {
    if ($wanted.ContainsKey($id)) { continue }
    if ($PSCmdlet.ShouldProcess($id, "Remove from '$groupName' (not in the registry)")) {
        Invoke-Az ad group member remove --group $group.id --member-id $id | Out-Null
        Write-Output "Removed $id."
    }
}

Write-Output "officerGroupObjectId=$($group.id)"
