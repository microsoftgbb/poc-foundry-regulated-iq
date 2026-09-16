#requires -Version 7.0
<#
.SYNOPSIS
  Toggle public network access on the Foundry account. Use this live during a demo.

.DESCRIPTION
  Two settings control reachability and BOTH matter:
    publicNetworkAccess       Enabled | Disabled
    networkAcls.defaultAction Allow   | Deny

  Setting publicNetworkAccess=Enabled while defaultAction stays Deny still returns 403.
  That is the most common "I flipped the toggle and it is still blocked" trap.

  Toggling does NOT require re-publishing the agent. enable_m365_public_endpoint stays set;
  it simply becomes redundant while public access is on, and resumes its job when off.

.EXAMPLE
  ./06-toggle-public-access.ps1 -Mode Private
  ./06-toggle-public-access.ps1 -Mode Public
#>
param(
    [Parameter(Mandatory)][ValidateSet("Public", "Private")][string]$Mode
)
. "$PSScriptRoot/00-variables.ps1"

if ($Mode -eq "Public") {
    $props = '{\"publicNetworkAccess\":\"Enabled\",\"networkAcls\":{\"defaultAction\":\"Allow\",\"ipRules\":[],\"virtualNetworkRules\":[]}}'
} else {
    $props = '{\"publicNetworkAccess\":\"Disabled\",\"networkAcls\":{\"defaultAction\":\"Deny\",\"ipRules\":[],\"virtualNetworkRules\":[]}}'
}

Write-Host "Setting network access to $Mode ..." -ForegroundColor Cyan
az resource patch --ids $AccountId --api-version 2025-06-01 --properties $props `
    --query "{pna:properties.publicNetworkAccess, acl:properties.networkAcls.defaultAction}" -o json

Write-Host "Allow 30-40s for the change to propagate before testing." -ForegroundColor Yellow
