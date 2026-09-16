# ---------------------------------------------------------------------------
# Copy this file to 00-variables.ps1 and fill in your own values.
# 00-variables.ps1 is gitignored - never commit real tenant or resource names.
# ---------------------------------------------------------------------------

# Azure context
$SubscriptionId = "<your-subscription-id>"
$TenantId       = "<your-tenant-id>"
$ResourceGroup  = "<your-resource-group>"
$Location       = "eastus2"

# Foundry
$AccountName    = "<globally-unique-foundry-account-name>"
$ProjectName    = "proj-pna-demo"
$AgentName      = "private-teams-agent"
$ModelName      = "gpt-4.1-mini"

# Networking (existing VNet you want the private endpoint in)
$VnetResourceGroup = "<vnet-resource-group>"
$VnetName          = "<vnet-name>"
$PeSubnetName      = "snet-pe"
$PeSubnetPrefix    = "10.0.1.0/24"

# Bot Service
$BotName        = "bot-private-teams-agent"
$BotDisplayName = "Contoso Private Helpdesk"

# Publishing
# Shared = just you, no admin approval (maps to BotServiceRbac)
# Tenant = whole org, requires M365 admin approval (maps to BotServiceTenant)
$PublishScope   = "Shared"
$AppVersion     = "1.0.0"

# ---------------------------------------------------------------------------
# Derived - no need to edit
# ---------------------------------------------------------------------------
$ProjectEndpoint = "https://$AccountName.services.ai.azure.com/api/projects/$ProjectName"
$AccountId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName"

function Get-FoundryToken {
    az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
}

function Get-FoundryHeaders {
    param([string]$ContentType = "application/json")
    @{ Authorization = "Bearer $(Get-FoundryToken)"; "Content-Type" = $ContentType }
}
