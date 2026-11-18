$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$manifests = @($env:NATIVE_MANIFEST | ConvertFrom-Json -AsHashtable)
$names = @($env:DOMAIN_NAMES | ConvertFrom-Json)
$subscription = '6ab9178f-09bc-45be-ba47-f682147eb1f0'
$group = 'rg-regiq-caldova-poc'
$verifyOnly = $env:NATIVE_VERIFY_ONLY -eq 'true'
$context = Get-AzContext
if ($context.Subscription.Id -ne $subscription -or
    $context.Tenant.Id -ne '95287129-9bbb-4084-8485-dc845ae7d143') {
    throw 'The private configuration job is not authenticated to Caldova.'
}
$audiences = @{
    'management.azure.com' = 'https://management.azure.com/'
}
foreach ($name in $names) {
    if ($name -notmatch '^regiq-[ab]-[a-z0-9]{13}$') {
        throw 'Unexpected pilot domain name.'
    }
    $audiences["$name.cognitiveservices.azure.com"] = 'https://cognitiveservices.azure.com/'
    $audiences["$name.services.ai.azure.com"] = 'https://ai.azure.com/'
    $audiences["$name.search.windows.net"] = 'https://search.azure.com/'
}

function Assert-PrivateResolution {
    param([string] $HostName)
    $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
    if ($addresses.Count -eq 0) { throw "No DNS records for $HostName." }
    foreach ($address in $addresses) {
        $bytes = $address.GetAddressBytes()
        $private = $bytes.Length -eq 4 -and (
            $bytes[0] -eq 10 -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
        )
        if (-not $private) { throw "$HostName is not exclusively private." }
    }
}

function Invoke-NativeRequest {
    param([string] $Method, [string] $Url, $Body = $null, [switch] $AllowNotFound,
          [int] $TimeoutSeconds = 60)
    $uri = [Uri] $Url
    if ($uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or -not $audiences.ContainsKey($uri.Host)) {
        throw 'Unexpected configuration endpoint.'
    }
    if ($uri.Host -eq 'management.azure.com') {
        $valid = $false
        foreach ($name in $names) {
            $projectPrefix = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.CognitiveServices/accounts/$name/projects/caseiq"
            if ($uri.AbsolutePath.StartsWith("$projectPrefix/connections/", [StringComparison]::OrdinalIgnoreCase) -or
                ($Method -eq 'GET' -and $uri.AbsolutePath.Equals("$projectPrefix/capabilityHosts/caseiq", [StringComparison]::OrdinalIgnoreCase))) {
                $valid = $true
            }
        }
        if (-not $valid) { throw 'Unexpected ARM configuration scope.' }
    }
    $audience = $audiences[$uri.Host]
    if ($audience -eq 'https://ai.azure.com/' -and
        $uri.AbsolutePath.StartsWith('/contentunderstanding/')) {
        $audience = 'https://cognitiveservices.azure.com/'
    }
    $token = Get-AzAccessToken -ResourceUrl $audience
    $parameters = @{
        Method = $Method
        Uri = $uri
        Authentication = 'Bearer'
        Token = $token.Token
        ContentType = 'application/json'
        MaximumRedirection = 0
        TimeoutSec = $TimeoutSeconds
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 60 -Compress }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $response = Invoke-WebRequest @parameters
        if ($response.StatusCode -ne 429 -or $attempt -eq 4) { break }
        $wait = [int] (5 * [Math]::Pow(2, $attempt))
        if ($response.Headers.ContainsKey('Retry-After')) {
            $retryAfter = [string] ($response.Headers['Retry-After'] | Select-Object -First 1)
            if (-not [int]::TryParse($retryAfter, [ref] $wait) -or $wait -lt 0 -or $wait -gt 120) {
                throw 'Azure throttled the request beyond the bounded retry budget.'
            }
        }
        Write-Warning "Azure throttled $($uri.Host); retrying after $wait seconds."
        Start-Sleep -Seconds $wait
    }
    if ($AllowNotFound -and $Method -eq 'GET' -and $response.StatusCode -eq 404) {
        return @{ Status = 404; Headers = $response.Headers; Data = @{} }
    }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Native configuration returned HTTP $($response.StatusCode) from $($uri.Host)."
    }
    $data = @{}
    if ($response.Content) { $data = $response.Content | ConvertFrom-Json -AsHashtable }
    return @{
        Status = $response.StatusCode
        Headers = $response.Headers
        Data = $data
    }
}

function Assert-ExpectedConfiguration {
    param($Expected, $Actual, [string] $Path)
    if ($Expected -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary]) {
            throw "Configuration object missing: $Path."
        }
        foreach ($key in $Expected.Keys) {
            if (-not $Actual.Contains($key)) { throw "Configuration field missing: $Path.$key." }
            Assert-ExpectedConfiguration $Expected[$key] $Actual[$key] "$Path.$key"
        }
    } elseif ($Expected -is [array]) {
        if ($Actual -isnot [array] -or $Expected.Count -ne $Actual.Count) {
            throw "Configuration array mismatch: $Path."
        }
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            Assert-ExpectedConfiguration $Expected[$i] $Actual[$i] "$Path[$i]"
        }
    } elseif ($Expected -cne $Actual) {
        throw "Configuration value mismatch: $Path."
    }
}

foreach ($hostName in $audiences.Keys) {
    if ($hostName -ne 'management.azure.com') { Assert-PrivateResolution $hostName }
}

foreach ($manifest in $manifests) {
    if ($manifest.consumerAccessEnabled -ne $false) { throw 'Consumer release is disabled.' }
    $connection = @($manifest.requests | Where-Object name -eq 'mcp-connection')[0]
    $connectionUrl = [string] $connection.url
    $projectUrl = $connectionUrl.Substring(0, $connectionUrl.IndexOf('/connections/', [StringComparison]::Ordinal))
    $hostResponse = Invoke-NativeRequest 'GET' "$projectUrl/capabilityHosts/caseiq?api-version=2025-06-01"
    $properties = $hostResponse.Data.properties
    if ($properties.provisioningState -ne 'Succeeded') {
        throw 'Native BYO project capability host is not ready.'
    }
    foreach ($field in $manifest.runtimeBindings.Keys) {
        $binding = $manifest.runtimeBindings[$field]
        if (-not $properties.ContainsKey($field) -or
            @($properties[$field]).Count -ne 1 -or $properties[$field][0] -ne $binding.name) {
            throw "Unexpected native BYO host binding: $field."
        }
        $connectionResponse = Invoke-NativeRequest 'GET' "$projectUrl/connections/$($binding.name)?api-version=2025-10-01-preview"
        $actual = $connectionResponse.Data.properties
        if ($actual.authType -ne 'AAD' -or $actual.useWorkspaceManagedIdentity -ne $true -or
            $actual.category -ne $binding.category -or
            $actual.target.TrimEnd('/') -cne $binding.target.TrimEnd('/') -or
            $actual.metadata.ResourceId -ne $binding.resourceId) {
            throw "Native BYO connection $($binding.name) does not match its isolated store."
        }
    }
}

foreach ($manifest in $manifests) {
    $analyzer = @($manifest.requests | Where-Object name -eq 'custom-analyzer')[0]
    $endpoint = ([Uri] $analyzer.url).GetLeftPart([UriPartial]::Authority)
    $base = Invoke-NativeRequest 'GET' "$endpoint/contentunderstanding/analyzers/prebuilt-document?api-version=2025-11-01"
    foreach ($kind in $analyzer.body.models.Keys) {
        if (-not $base.Data.supportedModels.ContainsKey($kind) -or
            $analyzer.body.models[$kind] -notin $base.Data.supportedModels[$kind]) {
            throw "Content Understanding does not advertise the configured $kind model."
        }
    }
    foreach ($request in $manifest.requests) {
        $readUrl = [string] $request.url
        if ($request.name -in @('custom-analyzer', 'prompt-agent')) {
            if ($request.name -eq 'prompt-agent') {
                $readUrl = $readUrl.Replace('/agents?', "/agents/$($request.body.name)?")
            }
            $existing = Invoke-NativeRequest 'GET' $readUrl -AllowNotFound
            if ($existing.Status -ne 404) {
                if ($request.name -eq 'prompt-agent') {
                    $tool = $existing.Data.versions.latest.definition.tools[0]
                    Write-Output ("Agent tool policy: " + (@{
                        allowed_tools = $tool.allowed_tools
                        require_approval = $tool.require_approval
                    } | ConvertTo-Json -Depth 8 -Compress))
                    Assert-ExpectedConfiguration $request.body.definition $existing.Data.versions.latest.definition 'prompt-agent.definition'
                    if (-not $existing.Data.versions.latest.version) {
                        throw 'Existing agent has no latest version.'
                    }
                } else {
                    Assert-ExpectedConfiguration $request.body $existing.Data $request.name
                    if ($existing.Data.status -ne 'ready') { throw 'Existing analyzer is not ready.' }
                }
                Write-Output "Verified $($manifest.officerObjectId): $($request.name)"
                continue
            }
        }
        if ($verifyOnly) {
            if ($request.name -eq 'datasources') {
                $readUrl += '&includeConnectionString=true'
            }
            $response = Invoke-NativeRequest 'GET' $readUrl
            if ($request.name -eq 'mcp-connection') {
                Write-Output ("MCP sharing flag: " + ($response.Data.properties.isSharedToAll | ConvertTo-Json -Compress))
            }
            Assert-ExpectedConfiguration $request.body $response.Data $request.name
            if ($request.name -eq 'custom-analyzer' -and $response.Data.status -ne 'ready') {
                throw 'Custom analyzer is not ready.'
            }
            if ($request.name -eq 'indexers' -and $response.Data.Contains('schedule') -and
                $null -ne $response.Data.schedule) {
                throw 'The approved-content indexer must remain unscheduled.'
            }
            Write-Output "Verified $($manifest.officerObjectId): $($request.name)"
            continue
        }
        $response = Invoke-NativeRequest $request.method $request.url $request.body
        $operation = $null
        if ($response.Headers.ContainsKey('Operation-Location')) {
            $operation = [string] ($response.Headers['Operation-Location'] | Select-Object -First 1)
        }
        if ($response.Status -eq 202 -and -not $operation) {
            throw 'Azure accepted an operation without a pollable URL.'
        }
        if ($request.name -eq 'custom-analyzer' -and -not $operation -and
            $response.Data.status -notin @('Succeeded', 'Ready')) {
            throw 'Analyzer creation returned neither a completed state nor a pollable URL.'
        }
        if ($operation) {
            $operationUri = [Uri] [string] $operation
            if ($operationUri.Authority -ne ([Uri] $request.url).Authority -or
                -not $operationUri.AbsolutePath.StartsWith('/contentunderstanding/')) {
                throw 'Unexpected asynchronous operation endpoint.'
            }
            $deadline = [DateTime]::UtcNow.AddMinutes(10)
            do {
                $response = Invoke-NativeRequest 'GET' ([string] $operation)
                $state = [string] $response.Data.status
                if ($state -eq 'Succeeded') { break }
                if ($state -notin @('Running', 'NotStarted')) {
                    throw "Native configuration operation failed: $state."
                }
                if ([DateTime]::UtcNow -ge $deadline) { throw 'Configuration operation timed out.' }
                Start-Sleep -Seconds 3
            } while ($true)
        }
        if ($request.name -eq 'prompt-agent') {
            if (-not $response.Data.versions.latest.version) {
                throw 'Agent creation returned no latest version.'
            }
            Assert-ExpectedConfiguration $request.body.definition $response.Data.versions.latest.definition 'prompt-agent.definition'
        }
        Write-Output "Configured $($manifest.officerObjectId): $($request.name)"
    }
}

if ($env:NATIVE_SMOKE_TEST -eq 'true') {
    foreach ($manifest in $manifests) {
        $agent = @($manifest.requests | Where-Object name -eq 'prompt-agent')[0]
        $endpoint = ([string] $agent.url).Replace('/agents?api-version=v1', "/agents/$($agent.body.name)/endpoint/protocols/openai")
        $conversation = Invoke-NativeRequest 'POST' "$endpoint/conversations?api-version=v1" @{}
        if (-not $conversation.Data.id) { throw 'Smoke test created no conversation.' }
        $response = Invoke-NativeRequest 'POST' "$endpoint/responses?api-version=v1" @{
            conversation = $conversation.Data.id
            input = 'What approved case evidence supports the synthetic marker REGIQ_SMOKE_20261117? Use knowledge_base_retrieve; do not infer missing evidence.'
            stream = $false
        } -TimeoutSeconds 180
        if ($response.Data.status -ne 'completed') { throw 'Native smoke response did not complete.' }
        $calls = @($response.Data.output | Where-Object {
            $_.type -eq 'mcp_call' -and $_.name -eq 'knowledge_base_retrieve' -and
            $_.server_label -eq 'case-evidence'
        })
        if ($calls.Count -eq 0) { throw 'Smoke response made no verified IQ retrieval call.' }
        foreach ($call in $calls) {
            if ($call.Contains('error') -and $null -ne $call.error) {
                throw 'Smoke response contains a failed IQ retrieval call.'
            }
        }
        Write-Output "Smoke verified $($manifest.officerObjectId): response $($response.Data.id); IQ calls $($calls.Count)."
    }
}

# Optional end-to-end evidence checks: each case asks one officer's agent a
# question about synthetic test evidence and asserts required and forbidden
# values, proving both retrieval of own approved evidence and cross-officer
# isolation.
$e2eFailures = 0
foreach ($case in @(if ($env:NATIVE_E2E_CASES) { $env:NATIVE_E2E_CASES | ConvertFrom-Json -AsHashtable } else { @() })) {
    $manifest = @($manifests | Where-Object { $_.officerObjectId -eq $case.officerObjectId })[0]
    $agent = @($manifest.requests | Where-Object name -eq 'prompt-agent')[0]
    $endpoint = ([string] $agent.url).Replace('/agents?api-version=v1', "/agents/$($agent.body.name)/endpoint/protocols/openai")
    $conversation = Invoke-NativeRequest 'POST' "$endpoint/conversations?api-version=v1" @{}
    $response = Invoke-NativeRequest 'POST' "$endpoint/responses?api-version=v1" @{
        conversation = $conversation.Data.id
        input = $case.question
        stream = $false
    } -TimeoutSeconds 180
    $text = (@($response.Data.output | Where-Object { $_.type -eq 'message' } |
        ForEach-Object { @($_.content) | ForEach-Object { $_.text } }) -join ' ')
    $normalized = $text.Replace(',', '')
    $ok = $response.Data.status -eq 'completed'
    foreach ($value in @($case.mustContain)) { if ($value -and -not $normalized.Contains($value)) { $ok = $false } }
    foreach ($value in @($case.mustNotContain)) { if ($value -and $normalized.Contains($value)) { $ok = $false } }
    if (-not $ok) { $e2eFailures++ }
    Write-Output "E2E $($case.name): $(if ($ok) { 'PASS' } else { 'FAIL' }) (response $($response.Data.id))"
    Write-Output "  answer: $($text.Replace("`n", ' '))"
}
if ($e2eFailures -gt 0) { throw "$e2eFailures end-to-end evidence checks failed." }

# Optional: emit each agent's validated Teams app package (base64) so an
# officer can upload it as a custom app. Does not submit to the catalog and
# fails if packaging alters the BotServiceRbac authorization scheme.
if ($env:NATIVE_TEAMS_PACKAGE -eq 'true') {
    foreach ($manifest in $manifests) {
        $agent = @($manifest.requests | Where-Object name -eq 'prompt-agent')[0]
        $project = ([string] $agent.url).Replace('/agents?api-version=v1', '')
        $label = if ($project -match 'regiq-a-') { 'officer-a' } else { 'officer-b' }
        $uri = [Uri] "$project/agents/$($agent.body.name)/microsoft365/zip?api-version=v1"
        if (-not $audiences.ContainsKey($uri.Host)) { throw 'Unexpected package endpoint.' }
        Assert-PrivateResolution $uri.Host
        # Microsoft 365 validates packages only for a delegated user caller.
        if (-not $env:OPERATOR_TOKEN) { throw 'Teams packaging requires an operator token.' }
        $userToken = ConvertTo-SecureString $env:OPERATOR_TOKEN -AsPlainText -Force
        $body = @{
            agentDisplayName = "Case IQ - $(if ($label -eq 'officer-a') { 'Officer A' } else { 'Officer B' })"
            performBotRegistration = $true; publishScope = 'Shared'; publishAsAutopilot = $false
            appVersion = '1.0.0'
            shortDescription = 'Ask about your own approved case documents.'
            fullDescription = 'Answers questions using only the approved case evidence of the assigned officer, with document and page references.'
            developerName = 'Caldova Revenue Authority'; developerWebsiteUrl = 'https://azure.microsoft.com'
            privacyUrl = 'https://privacy.microsoft.com'; termsOfUseUrl = 'https://www.microsoft.com/legal/terms-of-use'
        }
        $zip = Invoke-WebRequest -Method POST -Uri $uri -Authentication Bearer -Token $userToken `
            -ContentType 'application/json' -Body (ConvertTo-Json -InputObject $body -Compress) `
            -TimeoutSec 180 -SkipHttpErrorCheck -MaximumRedirection 0
        if ($zip.StatusCode -ne 200) { throw "Package $label failed with HTTP $($zip.StatusCode): $($zip.Content)" }
        Write-Output "PACKAGE $label $([Convert]::ToBase64String($zip.RawContentStream.ToArray()))"
        $after = Invoke-NativeRequest 'GET' "$project/agents/$($agent.body.name)?api-version=v1"
        $types = @($after.Data.agent_endpoint.authorization_schemes | ForEach-Object { $_.type })
        if ('BotServiceTenant' -in $types -or 'BotServiceRbac' -notin $types) { throw 'Packaging changed the authorization scheme.' }
        Write-Output "Schemes after packaging ${label}: $($types -join ',')"
    }
}

Write-Output 'Native administrative checks finished.'
