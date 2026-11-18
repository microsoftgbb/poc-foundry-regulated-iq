$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Publishes each officer's native agent to Microsoft Teams with Shared scope.
# Shared scope applies BotServiceRbac: only users holding an interaction role
# on that officer's project (Foundry Agent Consumer) can chat with the agent.
# The Activity Protocol route is the only public exception; it stays
# source-IP filtered and token authorized by Foundry. Runs inside the VNet
# because project APIs are private.

$domains = @($env:PUBLISH_DOMAINS | ConvertFrom-Json -AsHashtable)
$token = ConvertTo-SecureString $env:OPERATOR_TOKEN -AsPlainText -Force
$appVersion = $env:PUBLISH_APP_VERSION

function Invoke-Project {
    param([string] $Method, [string] $Url, $Body = $null, [string] $ContentType = 'application/json')
    $uri = [Uri] $Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '^regiq-[ab]-[a-z0-9]{13}\.services\.ai\.azure\.com$') {
        throw 'Unexpected project endpoint.'
    }
    foreach ($address in [System.Net.Dns]::GetHostAddresses($uri.Host)) {
        if ($address.GetAddressBytes()[0] -ne 10) { throw "$($uri.Host) is not private." }
    }
    $parameters = @{
        Method = $Method; Uri = $uri; Authentication = 'Bearer'; Token = $token
        TimeoutSec = 180; SkipHttpErrorCheck = $true; MaximumRedirection = 0
    }
    if ($null -ne $Body) {
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
        $parameters.ContentType = $ContentType
    }
    $response = Invoke-WebRequest @parameters
    $data = $null
    if ($response.Content) { try { $data = $response.Content | ConvertFrom-Json -AsHashtable -Depth 50 } catch { } }
    return [pscustomobject] @{ Status = [int] $response.StatusCode; Data = $data; Raw = [string] $response.Content }
}

$failures = 0
foreach ($domain in $domains) {
    $project = "https://$($domain.foundryAccount).services.ai.azure.com/api/projects/caseiq"
    $agentUrl = "$project/agents/caseiq?api-version=v1"
    try {
        $agent = Invoke-Project GET $agentUrl
        if ($agent.Status -ne 200) { throw "Read agent failed with HTTP $($agent.Status): $($agent.Raw)" }
        $schemes = [System.Collections.Generic.List[object]]::new()
        $existing = @()
        if ($agent.Data.ContainsKey('agent_endpoint') -and $agent.Data.agent_endpoint -and
            $agent.Data.agent_endpoint.ContainsKey('authorization_schemes')) {
            $existing = @($agent.Data.agent_endpoint.authorization_schemes)
        }
        foreach ($scheme in $existing) {
            if ($scheme.type -notin 'BotServiceRbac', 'BotServiceTenant') { $schemes.Add($scheme) }
        }
        if (-not @($schemes | Where-Object { $_.type -in 'AzureRbac', 'Entra' })) { $schemes.Add(@{ type = 'AzureRbac' }) }
        $schemes.Add(@{ type = 'BotServiceRbac' })
        $patch = Invoke-Project PATCH $agentUrl @{
            agent_endpoint = @{
                protocol_configuration = @{
                    responses = @{}
                    activity = @{ enable_m365_public_endpoint = $true }
                }
                authorization_schemes = $schemes.ToArray()
            }
        } 'application/merge-patch+json'
        if ($patch.Status -notin 200, 201) { throw "Endpoint update failed with HTTP $($patch.Status): $($patch.Raw)" }
        $verified = Invoke-Project GET $agentUrl
        $endpoint = $verified.Data.agent_endpoint
        $types = @($endpoint.authorization_schemes | ForEach-Object { $_.type })
        if ('BotServiceTenant' -in $types -or 'BotServiceRbac' -notin $types -or
            -not $endpoint.protocol_configuration.activity.enable_m365_public_endpoint) {
            throw 'Agent endpoint does not have the expected Activity and BotServiceRbac configuration.'
        }
        Write-Output "Endpoint $($domain.officerLabel): schemes $($types -join ','); activity public route enabled."

        $request = @{
            agentDisplayName = $domain.displayName
            performBotRegistration = $true
            publishScope = 'Shared'
            publishAsAutopilot = $false
            appVersion = $appVersion
            shortDescription = 'Ask about your own approved case documents.'
            fullDescription = 'Answers questions using only the approved case evidence of the assigned officer, with document and page references.'
            developerName = 'Caldova Revenue Authority'
            developerWebsiteUrl = 'https://azure.microsoft.com'
            privacyUrl = 'https://privacy.microsoft.com'
            termsOfUseUrl = 'https://www.microsoft.com/legal/terms-of-use'
        }
        $publish = Invoke-Project POST "$project/agents/caseiq/microsoft365/publish?api-version=v1" $request
        if ($publish.Status -notin 200, 201, 202) { throw "Publish failed with HTTP $($publish.Status): $($publish.Raw)" }
        Write-Output "Published $($domain.officerLabel): $($publish.Raw)"
    } catch {
        $failures++
        Write-Output "Publishing failed for $($domain.officerLabel): $($_.Exception.Message)"
    }
}
if ($failures -gt 0) { exit 1 }
Write-Output 'Teams publishing finished.'
