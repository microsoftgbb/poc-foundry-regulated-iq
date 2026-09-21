#requires -Version 7.0
<#
.SYNOPSIS
  Create the three specialist sub-agents as persistent Foundry prompt agents.
.NOTES
  POST /agents/{name}/versions requires the body wrapped in a "definition" object.
  Run from inside the VNet when public network access is disabled.
#>
. "$PSScriptRoot/00-variables.ps1"

$defs = @{
  "invoice-extractor" = "You extract invoice data. Return a compact JSON object with keys: vendor, invoice_number, po_number, line_items (list of {desc, qty, unit_price, amount}), subtotal, tax, shipping, total. Only output the JSON."
  "invoice-validator" = "You are an accounts-payable validator. Given extracted invoice JSON verify: (a) each line amount = qty * unit_price; (b) subtotal = sum of line amounts; (c) total = subtotal + tax + shipping; (d) call out any item not on the referenced PO. Report each check as PASS/FAIL with the numbers and list exceptions needing human review."
  "invoice-approver"  = "You are an approval officer. Based on the validator findings decide APPROVE, HOLD or REJECT. Give a two-sentence rationale and, if HOLD, state exactly what a human must resolve. Be concise."
}

foreach ($name in $defs.Keys) {
    $body = @{
        definition = @{ kind = "prompt"; model = $ModelName; instructions = $defs[$name] }
        description = "Invoice multi-agent demo - $name"
    } | ConvertTo-Json -Depth 6

    Write-Host "Creating $name ..." -ForegroundColor Cyan
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$ProjectEndpoint/agents/$name/versions?api-version=v1" `
                -Headers (Get-FoundryHeaders) -Body $body
        Write-Host "  created version $($r.version)" -ForegroundColor Green
    } catch {
        Write-Host "  failed: $($_.ErrorDetails.Message)" -ForegroundColor Red
    }
}
