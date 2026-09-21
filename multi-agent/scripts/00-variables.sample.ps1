# ---------------------------------------------------------------------------
# Copy to 00-variables.ps1 (gitignored) and fill in your own values.
# ---------------------------------------------------------------------------

$SubscriptionId = "<your-subscription-id>"
$TenantId       = "<your-tenant-id>"
$ResourceGroup  = "<your-resource-group>"
$Location       = "eastus2"

# Foundry (from the network-secured standard agent setup)
$AccountName    = "<your-foundry-account>"
$ProjectName    = "<your-project>"
$ModelName      = "gpt-4.1"

# Agents
$OrchestratorName = "invoice-orchestrator"
$SubAgents        = @("invoice-extractor", "invoice-validator", "invoice-approver")

# Teams publishing
$BotName        = "bot-invoice-orchestrator"
$BotDisplayName = "Invoice Orchestrator"
$PublishScope   = "Shared"     # Shared -> BotServiceRbac, no admin approval
$AppVersion     = "1.0.0"

# ---------------------------------------------------------------------------
# Derived
# ---------------------------------------------------------------------------
$ProjectEndpoint = "https://$AccountName.services.ai.azure.com/api/projects/$ProjectName"
$ProjectScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/$ProjectName"

function Get-FoundryToken {
    az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
}
function Get-FoundryHeaders {
    param([string]$ContentType = "application/json")
    @{ Authorization = "Bearer $(Get-FoundryToken)"; "Content-Type" = $ContentType }
}
