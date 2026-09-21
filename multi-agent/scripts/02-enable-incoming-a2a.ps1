#requires -Version 7.0
<#
.SYNOPSIS
  Enable incoming A2A on each sub-agent: publish an agent_card and add "a2a" to the protocols.
.NOTES
  Both parts are required. Adding the protocol without an agent_card leaves the card
  unresolvable and the caller fails with "Failed to fetch agent card: 404".
  Foundry serves the card at .../endpoint/protocols/a2a/agentCard/v0.3 - do NOT hard-code it anywhere.
#>
. "$PSScriptRoot/00-variables.ps1"

$cards = @{
  "invoice-extractor" = @{ desc = "Extracts structured fields from raw invoice text"; id = "extract"; name = "Invoice extraction"; sdesc = "Return invoice fields as JSON" }
  "invoice-validator" = @{ desc = "Validates invoice math and PO compliance";        id = "validate"; name = "Invoice validation"; sdesc = "Check totals and flag off-PO items" }
  "invoice-approver"  = @{ desc = "Issues APPROVE / HOLD / REJECT decisions";         id = "approve";  name = "Invoice approval";  sdesc = "Decide approval from validator findings" }
}

foreach ($name in $cards.Keys) {
    $c = $cards[$name]
    $body = @{
        agent_card = @{
            description = $c.desc
            version     = "1.0"
            skills      = @(@{ id = $c.id; name = $c.name; description = $c.sdesc })
        }
        agent_endpoint = @{
            protocol_configuration = @{ responses = @{}; a2a = @{} }
        }
    } | ConvertTo-Json -Depth 8

    Write-Host "Enabling incoming A2A on $name ..." -ForegroundColor Cyan
    try {
        $r = Invoke-RestMethod -Method Patch -Uri "$ProjectEndpoint/agents/$name`?api-version=v1" `
                -Headers (Get-FoundryHeaders) -Body $body
        Write-Host "  protocols: $($r.agent_endpoint.protocols -join ', ')" -ForegroundColor Green
    } catch {
        Write-Host "  failed: $($_.ErrorDetails.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "A2A endpoints (use as connection targets in 03):" -ForegroundColor Cyan
foreach ($name in $cards.Keys) { Write-Host "  $ProjectEndpoint/agents/$name/endpoint/protocols/a2a" }
