$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Reconciles officers' uploaded PDFs.
# Option A (INGEST_DOMAINS): each officer's own evidence store and index:
#   upload (current Blob version) -> Content Understanding custom analyzer
#   -> approval (Blob index tag set by the approver role) -> approved records
#   -> private indexer run.
#   A version that is deleted, replaced or loses its approval is withdrawn by
#   rewriting its records as approved=false tombstones, which the knowledge
#   source base filter excludes.
# Option B (INGEST_SHARED): one shared pipeline for every officer in the
#   registry (INGEST_OFFICERS, from infra/officers.json): shared analyzer ->
#   approval tag -> records pushed to the shared index with the native ACL
#   userIds = [owning officer]; withdrawn versions are deleted from the index.
# The owning officer always comes from the container binding in the registry,
# never from document content.

$domains = @($env:INGEST_DOMAINS | ConvertFrom-Json -AsHashtable)
$subscription = '6ab9178f-09bc-45be-ba47-f682147eb1f0'
$sourceStorage = 'regiqvqx35xnseaqaw'
$approvalTag = 'approval'
$approvedValue = 'approved'
$cuApi = '2025-11-01'
$searchApi = '2026-08-01-preview'
$storageVersion = '2023-11-03'
$officers = @($env:INGEST_OFFICERS | ConvertFrom-Json -AsHashtable)
$bindings = @{}
$containers = @{}
foreach ($officer in $officers) {
    if ($officer.objectId -notmatch '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' -or
        $officer.container -notmatch '^officer-[a-z0-9]{1,30}-pending$' -or
        $bindings.ContainsKey($officer.objectId) -or $containers.ContainsKey($officer.container)) {
        throw 'Invalid or duplicate officer registry entry.'
    }
    $bindings[$officer.objectId] = $officer.container
    $containers[$officer.container] = $true
}
if ($bindings.Count -eq 0) { throw 'The officer registry is empty.' }

$context = Get-AzContext
if ($context.Subscription.Id -ne $subscription -or
    $context.Tenant.Id -ne '95287129-9bbb-4084-8485-dc845ae7d143') {
    throw 'The ingestion job is not authenticated to Caldova.'
}
if ($domains.Count -ne 2) { throw 'Expected exactly two officer domains.' }

$allowedHosts = @{ "$sourceStorage.blob.core.windows.net" = 'https://storage.azure.com/' }
foreach ($domain in $domains) {
    if ($bindings[$domain.officerObjectId] -ne $domain.sourceContainer) {
        throw 'Officer and source container binding mismatch.'
    }
    if ($domain.foundryAccount -notmatch '^regiq-[ab]-[a-z0-9]{13}$' -or
        $domain.searchService -ne $domain.foundryAccount -or
        $domain.evidenceStorage -notmatch '^riq[ab][a-z0-9]{13}$' -or
        $domain.analyzerId -ne "case_evidence_$($domain.analyzerSha256.Substring(0, 16))") {
        throw 'Unexpected domain configuration.'
    }
    $allowedHosts["$($domain.evidenceStorage).blob.core.windows.net"] = 'https://storage.azure.com/'
    $allowedHosts["$($domain.foundryAccount).services.ai.azure.com"] = 'https://cognitiveservices.azure.com/'
    $allowedHosts["$($domain.foundryAccount).cognitiveservices.azure.com"] = 'https://cognitiveservices.azure.com/'
    $allowedHosts["$($domain.searchService).search.windows.net"] = 'https://search.azure.com/'
}
# Option B (optional): mirror every officer's approved records into one shared
# index whose native ACL (userIds) holds the owning officer's object ID, so a
# single shared agent can retrieve with the caller's own token.
$shared = if ($env:INGEST_SHARED) { $env:INGEST_SHARED | ConvertFrom-Json -AsHashtable } else { $null }
if ($shared) {
    if ($shared.searchService -notmatch '^regiq-s-[a-z0-9]{13}$' -or $shared.index -ne 'case-evidence-shared' -or
        $shared.foundryAccount -ne $shared.searchService -or
        $shared.evidenceStorage -notmatch '^riqs[a-z0-9]{13}$' -or
        $shared.analyzerId -ne "case_evidence_$($shared.analyzerSha256.Substring(0, 16))") {
        throw 'Unexpected shared pipeline configuration.'
    }
    $allowedHosts["$($shared.searchService).search.windows.net"] = 'https://search.azure.com/'
    $allowedHosts["$($shared.evidenceStorage).blob.core.windows.net"] = 'https://storage.azure.com/'
    $allowedHosts["$($shared.foundryAccount).services.ai.azure.com"] = 'https://cognitiveservices.azure.com/'
    $allowedHosts["$($shared.foundryAccount).cognitiveservices.azure.com"] = 'https://cognitiveservices.azure.com/'
}
$sharedApi = '2026-10-01'
# Azure Portal blob properties deep link for option B citations. Officers
# open their own source PDFs in the Portal with Entra-only data access.
$sourceStorageId = "/subscriptions/$subscription/resourceGroups/rg-regiq-caldova-poc" +
    "/providers/Microsoft.Storage/storageAccounts/$sourceStorage"
$portalBlobBase = 'https://portal.azure.com/#@caldova63232896.onmicrosoft.com/view/Microsoft_Azure_Storage/BlobPropertiesBladeV2' +
    "/storageAccountId/$([Uri]::EscapeDataString($sourceStorageId))/path/"
$resolved = @{}
$tokens = @{}

function Get-CachedToken {
    param([string] $Audience)
    $cached = $tokens[$Audience]
    if ($cached -and $cached.ExpiresOn.UtcDateTime -gt [DateTime]::UtcNow.AddMinutes(5)) { return $cached }
    for ($attempt = 1; ; $attempt++) {
        try {
            $token = Get-AzAccessToken -ResourceUrl $Audience -WarningAction SilentlyContinue
            $tokens[$Audience] = $token
            return $token
        } catch {
            if ($attempt -ge 6) { throw }
            Start-Sleep -Seconds (10 * $attempt)
        }
    }
}

function Assert-PrivateResolution {
    param([string] $HostName)
    if ($resolved.ContainsKey($HostName)) { return }
    $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
    if ($addresses.Count -eq 0) { throw "No DNS records for $HostName." }
    foreach ($address in $addresses) {
        $bytes = $address.GetAddressBytes()
        if ($bytes.Length -ne 4 -or $bytes[0] -ne 10) {
            throw "$HostName is not exclusively private."
        }
    }
    $resolved[$HostName] = $true
}

function Invoke-Private {
    param([string] $Method, [string] $Url, $Body = $null, [string] $ContentType = 'application/json',
          [hashtable] $Headers = @{}, [int] $TimeoutSeconds = 120)
    $uri = [Uri] $Url
    if ($uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
        -not $allowedHosts.ContainsKey($uri.Host)) {
        throw 'Unexpected ingestion endpoint.'
    }
    Assert-PrivateResolution $uri.Host
    $token = Get-CachedToken $allowedHosts[$uri.Host]
    $requestHeaders = @{} + $Headers
    if ($allowedHosts[$uri.Host] -eq 'https://storage.azure.com/') {
        $requestHeaders['x-ms-version'] = $storageVersion
        $requestHeaders['x-ms-date'] = [DateTime]::UtcNow.ToString('R')
    }
    $parameters = @{
        Method = $Method
        Uri = $uri
        Authentication = 'Bearer'
        Token = $token.Token
        Headers = $requestHeaders
        MaximumRedirection = 0
        TimeoutSec = $TimeoutSeconds
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body
        $parameters.ContentType = $ContentType
    }
    # Only idempotent requests are replayed after a network failure; a lost
    # analysis POST response is not replayed so it cannot double-submit.
    $replayable = $Method -in 'GET', 'PUT'
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $response = Invoke-WebRequest @parameters
        } catch {
            if (-not $replayable -or $attempt -eq 4) { throw }
            Start-Sleep -Seconds ([int] (5 * [Math]::Pow(2, $attempt)))
            continue
        }
        if ($response.StatusCode -notin 429, 503 -or $attempt -eq 4) { break }
        Start-Sleep -Seconds ([int] (5 * [Math]::Pow(2, $attempt)))
    }
    return $response
}

function Assert-Status {
    param($Response, [int[]] $Expected, [string] $Operation)
    if ($Response.StatusCode -notin $Expected) {
        throw "$Operation failed with HTTP $($Response.StatusCode)."
    }
}

function Get-Sha256Hex {
    param([byte[]] $Bytes)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-TextSha256 {
    param([string] $Text)
    return Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertTo-StableJson {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress)
}

function Get-BlobList {
    param([string] $Account, [string] $Container, [string] $Prefix = '', [string] $Include = '')
    $items = @()
    $marker = ''
    do {
        $url = "https://$Account.blob.core.windows.net/$Container`?restype=container&comp=list&maxresults=5000"
        if ($Prefix) { $url += "&prefix=$([Uri]::EscapeDataString($Prefix))" }
        if ($Include) { $url += "&include=$Include" }
        if ($marker) { $url += "&marker=$([Uri]::EscapeDataString($marker))" }
        $response = Invoke-Private GET $url
        Assert-Status $response 200 "List $Container"
        $text = [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
        $xml = [xml] $text.TrimStart([char] 0xFEFF)
        foreach ($blob in @($xml.SelectNodes('/EnumerationResults/Blobs/Blob'))) {
            $tags = @{}
            foreach ($tag in @($blob.SelectNodes('Tags/TagSet/Tag'))) {
                $tags[$tag.SelectSingleNode('Key').InnerText] = $tag.SelectSingleNode('Value').InnerText
            }
            $versionNode = $blob.SelectSingleNode('VersionId')
            $currentNode = $blob.SelectSingleNode('IsCurrentVersion')
            $modifiedNode = $blob.SelectSingleNode('Properties/Last-Modified')
            $metadata = @{}
            $metadataNode = $blob.SelectSingleNode('Metadata')
            if ($metadataNode) {
                foreach ($entry in @($metadataNode.ChildNodes)) { $metadata[$entry.LocalName] = $entry.InnerText }
            }
            $items += [pscustomobject] @{
                Name = $blob.SelectSingleNode('Name').InnerText
                VersionId = if ($versionNode) { $versionNode.InnerText } else { '' }
                IsCurrent = $currentNode -and $currentNode.InnerText -eq 'true'
                Tags = $tags
                Metadata = $metadata
                LastModified = if ($modifiedNode) { [DateTimeOffset]::Parse($modifiedNode.InnerText).UtcDateTime } else { [DateTime]::MinValue }
            }
        }
        $next = $xml.SelectSingleNode('/EnumerationResults/NextMarker')
        $marker = if ($next) { $next.InnerText } else { '' }
    } while ($marker)
    return $items
}

function Get-BlobBytes {
    param([string] $Account, [string] $Container, [string] $Name, [string] $VersionId = '')
    $url = "https://$Account.blob.core.windows.net/$Container/$([Uri]::EscapeDataString($Name).Replace('%2F', '/'))"
    if ($VersionId) { $url += "?versionid=$([Uri]::EscapeDataString($VersionId))" }
    $response = Invoke-Private GET $url -TimeoutSeconds 300
    if ($response.StatusCode -eq 404) { return $null }
    Assert-Status $response 200 'Read Blob'
    return $response.RawContentStream.ToArray()
}

function Get-BlobJson {
    param([string] $Account, [string] $Container, [string] $Name)
    $bytes = Get-BlobBytes $Account $Container $Name
    if ($null -eq $bytes) { return $null }
    return [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 100
}

function Set-BlobJson {
    param([string] $Account, [string] $Container, [string] $Name, $Value, [hashtable] $Metadata = @{})
    $headers = @{ 'x-ms-blob-type' = 'BlockBlob' }
    foreach ($key in $Metadata.Keys) { $headers["x-ms-meta-$key"] = $Metadata[$key] }
    $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-StableJson $Value))
    $response = Invoke-Private PUT "https://$Account.blob.core.windows.net/$Container/$Name" `
        -Body $body -ContentType 'application/json' -Headers $headers
    Assert-Status $response 201 "Write $Container"
}

function Invoke-Analysis {
    param($Domain, [byte[]] $Pdf)
    $url = "https://$($Domain.foundryAccount).services.ai.azure.com/contentunderstanding/analyzers/" +
        "$($Domain.analyzerId):analyzeBinary?api-version=$cuApi&processingLocation=geography&stringEncoding=utf16"
    $response = Invoke-Private POST $url -Body $Pdf -ContentType 'application/pdf' -TimeoutSeconds 300
    Assert-Status $response 202 'Content Understanding analysis'
    $operation = [Uri] ([string] (@($response.Headers['Operation-Location'])[0]))
    if (-not $allowedHosts.ContainsKey($operation.Host) -or
        -not $operation.Host.StartsWith("$($Domain.foundryAccount).") -or
        -not $operation.AbsolutePath.StartsWith('/contentunderstanding/analyzerResults/')) {
        throw 'Unexpected Content Understanding operation location.'
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 5
        $poll = Invoke-Private GET $operation.AbsoluteUri
        Assert-Status $poll 200 'Content Understanding status'
        $result = $poll.Content | ConvertFrom-Json -AsHashtable -Depth 100
        switch ($result.status) {
            'Succeeded' { return $result }
            { $_ -in 'Failed', 'Canceled' } { throw "Content Understanding analysis $($result.status)." }
        }
    }
    throw 'Content Understanding analysis timed out.'
}

function Format-FieldValue {
    param($Field)
    if ($null -eq $Field) { return $null }
    foreach ($name in 'valueString', 'valueDate', 'valueNumber', 'valueInteger', 'valueBoolean', 'valueTime') {
        if ($Field.ContainsKey($name) -and $null -ne $Field[$name]) { return [string] $Field[$name] }
    }
    if ($Field.ContainsKey('valueArray') -and $Field.valueArray) {
        return ConvertTo-StableJson (@($Field.valueArray | ForEach-Object { Format-FieldValue $_ }))
    }
    if ($Field.ContainsKey('valueObject') -and $Field.valueObject) {
        $object = [ordered] @{}
        foreach ($key in ($Field.valueObject.Keys | Sort-Object)) { $object[$key] = Format-FieldValue $Field.valueObject[$key] }
        return ConvertTo-StableJson $object
    }
    return $null
}

function New-EvidenceRecords {
    param($Envelope, [string] $ApprovalId)
    $source = $Envelope.source
    $analysisSha = Get-TextSha256 (ConvertTo-StableJson $Envelope)
    $sourceUri = "https://$sourceStorage.blob.core.windows.net/$($source.container)/" +
        "$([Uri]::EscapeDataString($source.blob).Replace('%2F', '/'))?versionid=$([Uri]::EscapeDataString($source.version))"
    $fileName = ($source.blob -split '/')[-1]
    $records = [System.Collections.Generic.List[object]]::new()
    function Add-Record([string] $Title, [string] $Text, [int] $Start, [int] $End) {
        for ($offset = 0; $offset -lt $Text.Length; $offset += 12000) {
            $records.Add([ordered] @{
                id = Get-TextSha256 "$($source.officer_oid)|$($source.container)|$($source.blob)|$($source.version)|$ApprovalId|$($records.Count)"
                title = $Title
                content = $Text.Substring($offset, [Math]::Min(12000, $Text.Length - $offset))
                officer_oid = $source.officer_oid
                source_uri = $sourceUri
                source_version = $source.version
                source_sha256 = $source.sha256
                analyzer_version = $Envelope.analyzer_sha256
                analysis_sha256 = $analysisSha
                approval_id = $ApprovalId
                page_start = $Start
                page_end = $End
                approved = $true
            })
        }
    }
    $contents = @($Envelope.analysis.result.contents)
    if ($contents.Count -eq 0) { throw 'Analysis contained no document evidence.' }
    foreach ($content in $contents) {
        if ($content.kind -ne 'document') { throw 'Only document analysis can enter the evidence index.' }
        $markdown = [string] $content.markdown
        $pages = @($content.pages)
        if (-not $markdown.Trim() -or $pages.Count -eq 0) { throw 'Evidence must contain text and page grounding.' }
        $numbers = @()
        foreach ($page in $pages) {
            $number = [int] $page.pageNumber
            if ($number -lt 1) { throw 'Invalid page grounding.' }
            $numbers += $number
            $text = ''
            foreach ($span in @($page.spans)) {
                $offset = [int] $span.offset
                $length = [int] $span.length
                if ($offset -lt 0 -or $length -lt 0 -or $offset + $length -gt $markdown.Length) {
                    throw 'Page span is outside the analyzed content.'
                }
                $text += $markdown.Substring($offset, $length)
            }
            if ($text.Trim()) { Add-Record "$fileName (page $number)" $text $number $number }
        }
        if ($content.ContainsKey('fields') -and $content.fields) {
            $lines = @("Fields extracted by the custom analyzer from $fileName. Verify against the cited pages.")
            foreach ($name in ($content.fields.Keys | Sort-Object)) {
                $value = Format-FieldValue $content.fields[$name]
                if ($null -ne $value -and $value -ne '') { $lines += "${name}: $value" }
            }
            if ($lines.Count -gt 1) {
                $measure = $numbers | Measure-Object -Minimum -Maximum
                Add-Record "$fileName (extracted fields)" ($lines -join "`n") ([int] $measure.Minimum) ([int] $measure.Maximum)
            }
        }
    }
    if ($records.Count -eq 0) { throw 'Analysis produced no indexable text.' }
    return , $records.ToArray()
}

function Invoke-IndexerRun {
    param($Domain)
    $base = "https://$($Domain.searchService).search.windows.net/indexers/approved-content"
    $started = [DateTime]::UtcNow.AddSeconds(-5)
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $run = Invoke-Private POST "$base/run?api-version=$searchApi"
        if ($run.StatusCode -eq 202) { break }
        if ($run.StatusCode -ne 409) { Assert-Status $run 202 'Indexer run' }
        Start-Sleep -Seconds 10
    }
    Assert-Status $run 202 'Indexer run'
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 10
        $status = Invoke-Private GET "$base/status?api-version=$searchApi"
        Assert-Status $status 200 'Indexer status'
        $last = ($status.Content | ConvertFrom-Json -AsHashtable -Depth 50).lastResult
        if ($null -eq $last -or $null -eq $last.startTime -or
            ([DateTime] $last.startTime).ToUniversalTime() -lt $started) { continue }
        switch ($last.status) {
            'success' {
                Write-Output "Indexer $($Domain.officerObjectId): processed $($last.itemsProcessed), failed $($last.itemsFailed)."
                return
            }
            'inProgress' { continue }
            default { throw "Indexer $($Domain.officerObjectId) finished with status $($last.status)." }
        }
    }
    throw 'Indexer run timed out.'
}

# Builds the Portal link only from the fixed source account, the officer's
# bound container and the blob name parsed from the record's source_uri.
function Get-PortalUrl {
    param([string] $SourceUri, [string] $Container, [string] $Version)
    $uri = [Uri] $SourceUri
    if ($uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
        $uri.Host -ne "$sourceStorage.blob.core.windows.net" -or
        $uri.Query -ne "?versionid=$([Uri]::EscapeDataString($Version))") {
        throw 'Unexpected record source URI.'
    }
    $segments = @($uri.AbsolutePath.TrimStart('/').Split('/') | ForEach-Object { [Uri]::UnescapeDataString($_) })
    if ($segments.Count -lt 2 -or $segments[0] -ne $Container) { throw 'Record source is outside the officer container.' }
    $blob = ($segments[1..($segments.Count - 1)]) -join '/'
    if (-not $blob.ToLowerInvariant().EndsWith('.pdf') -or $blob -match '[\x00-\x1f]' -or
        $blob.Split('/') -contains '..' -or $blob.Split('/') -contains '.' -or $blob.Split('/') -contains '') {
        throw 'Unexpected record source blob name.'
    }
    return "$portalBlobBase$([Uri]::EscapeDataString("$Container/$blob"))/isDeleted~/false/tabToload~/0"
}

function Send-SharedActions {
    param([object[]] $Actions)
    for ($offset = 0; $offset -lt $Actions.Count; $offset += 500) {
        $batch = $Actions[$offset..([Math]::Min($offset + 500, $Actions.Count) - 1)]
        $body = ConvertTo-Json -InputObject @{ value = @($batch) } -Depth 20 -Compress
        $response = Invoke-Private POST "https://$($shared.searchService).search.windows.net/indexes('$($shared.index)')/docs/search.index?api-version=$sharedApi" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
        Assert-Status $response 200 'Shared index update'
    }
}

function Get-AnalysisEnvelope {
    param($Analyzer, [string] $Evidence, [string] $Officer, [string] $Container, $Blob, [string] $Key)
    $envelopeName = "$Officer/$Key.json"
    $envelope = Get-BlobJson $Evidence 'analysis-pending' $envelopeName
    if ($null -ne $envelope) { return $envelope }
    $pdf = Get-BlobBytes $sourceStorage $Container $Blob.Name $Blob.VersionId
    if ($null -eq $pdf) { return $null }
    $result = Invoke-Analysis $Analyzer $pdf
    if ($result.result.analyzerId -ne $Analyzer.analyzerId) {
        throw 'Analysis was not produced by the configured custom analyzer.'
    }
    $envelope = [ordered] @{
        source = [ordered] @{
            officer_oid = $Officer
            storage = $sourceStorage
            container = $Container
            blob = $Blob.Name
            version = $Blob.VersionId
            sha256 = Get-Sha256Hex $pdf
        }
        analyzer_id = $Analyzer.analyzerId
        analyzer_sha256 = $Analyzer.analyzerSha256
        analysis = $result
    }
    Set-BlobJson $Evidence 'analysis-pending' $envelopeName $envelope
    Write-Output "Analyzed $Officer/${Key}: awaiting approval." | Out-Host
    return Get-BlobJson $Evidence 'analysis-pending' $envelopeName
}

# Option B: one pipeline for every registry officer, straight into the shared
# ACL index. approved-content/<officer>/<key>.json records the pushed IDs so a
# withdrawal can delete exactly those documents.
function Invoke-SharedPipeline {
    param([string] $Officer, [string] $Container)
    $evidence = $shared.evidenceStorage
    $sources = @(Get-BlobList $sourceStorage $Container -Include 'versions,tags' |
        Where-Object { $_.IsCurrent -and $_.Name.ToLowerInvariant().EndsWith('.pdf') -and $_.VersionId })
    $approvedKeys = @{}
    $published = 0
    $withdrawn = 0
    foreach ($blob in $sources) {
        if ($blob.Name.Split('/') -contains '..' -or $blob.Name.Split('/') -contains '.') { continue }
        $key = (Get-TextSha256 "$Container/$($blob.Name)`n$($blob.VersionId)").Substring(0, 32)
        $envelope = Get-AnalysisEnvelope $shared $evidence $Officer $Container $blob $key
        if ($null -eq $envelope -or $blob.Tags[$approvalTag] -ne $approvedValue) { continue }
        if ($envelope.source.version -ne $blob.VersionId -or $envelope.source.container -ne $Container -or
            $envelope.source.officer_oid -ne $Officer -or $envelope.analyzer_sha256 -ne $shared.analyzerSha256) {
            throw 'Analysis envelope does not match the approved source version.'
        }
        $approvedKeys[$key] = $true
        $stateName = "$Officer/$key.json"
        $existing = @(Get-BlobList $evidence 'approved-content' -Prefix $stateName -Include 'metadata' |
            Where-Object { $_.Name -eq $stateName })
        if ($existing.Count -eq 1 -and $existing[0].Metadata['regiqstate'] -eq 'approved') { continue }
        Set-BlobJson $evidence 'approval-ledger' "$Officer/$key.json" ([ordered] @{
            approval_id = $key
            status = 'approved'
            mechanism = 'source-blob-index-tag'
            source = $envelope.source
            analyzer_sha256 = $envelope.analyzer_sha256
            analysis_sha256 = Get-TextSha256 (ConvertTo-StableJson $envelope)
            recorded_at = [DateTime]::UtcNow.ToString('o')
        })
        $records = New-EvidenceRecords $envelope $key
        $actions = @(foreach ($record in $records) {
            $document = [ordered] @{ '@search.action' = 'mergeOrUpload' }
            foreach ($field in $record.Keys) { $document[$field] = $record[$field] }
            $document['userIds'] = @($Officer)
            $document['portal_url'] = Get-PortalUrl ([string] $record['source_uri']) $Container ([string] $record['source_version'])
            $document
        })
        Send-SharedActions $actions
        Set-BlobJson $evidence 'approved-content' $stateName ([ordered] @{
            ids = @($records | ForEach-Object { $_.id }); recorded_at = [DateTime]::UtcNow.ToString('o')
        }) @{ regiqstate = 'approved' }
        $published++
        Write-Output "Shared published $Officer/${key}: $($records.Count) records."
    }
    foreach ($item in @(Get-BlobList $evidence 'approved-content' -Prefix "$Officer/" -Include 'metadata')) {
        $key = [IO.Path]::GetFileNameWithoutExtension($item.Name)
        if ($approvedKeys.ContainsKey($key) -or $item.Metadata['regiqstate'] -ne 'approved') { continue }
        $state = Get-BlobJson $evidence 'approved-content' $item.Name
        Send-SharedActions @(@($state.ids) | ForEach-Object { [ordered] @{ '@search.action' = 'delete'; id = $_ } })
        Set-BlobJson $evidence 'approved-content' $item.Name $state @{ regiqstate = 'withdrawn' }
        Set-BlobJson $evidence 'approval-ledger' "$Officer/$key.withdrawn.json" ([ordered] @{
            approval_id = $key; status = 'withdrawn'; recorded_at = [DateTime]::UtcNow.ToString('o')
        })
        $withdrawn++
        Write-Output "Shared withdrew $Officer/${key}: $(@($state.ids).Count) records."
    }
    Write-Output "Shared reconciled ${Officer}: $($sources.Count) current PDFs, $($approvedKeys.Count) approved, $published published, $withdrawn withdrawn."
}

$failures = 0
foreach ($domain in $domains) {
    $officer = $domain.officerObjectId
    $evidence = $domain.evidenceStorage
    $changed = $false
    try {
        $sources = @(Get-BlobList $sourceStorage $domain.sourceContainer -Include 'versions,tags' |
            Where-Object { $_.IsCurrent -and $_.Name.ToLowerInvariant().EndsWith('.pdf') -and $_.VersionId })
        $approvedKeys = @{}
        foreach ($blob in $sources) {
            if ($blob.Name.Split('/') -contains '..' -or $blob.Name.Split('/') -contains '.') { continue }
            $key = (Get-TextSha256 "$($domain.sourceContainer)/$($blob.Name)`n$($blob.VersionId)").Substring(0, 32)
            $envelopeName = "$officer/$key.json"
            $envelope = Get-BlobJson $evidence 'analysis-pending' $envelopeName
            if ($null -eq $envelope) {
                $pdf = Get-BlobBytes $sourceStorage $domain.sourceContainer $blob.Name $blob.VersionId
                if ($null -eq $pdf) { continue }
                $result = Invoke-Analysis $domain $pdf
                if ($result.result.analyzerId -ne $domain.analyzerId) {
                    throw 'Analysis was not produced by the configured custom analyzer.'
                }
                $envelope = [ordered] @{
                    source = [ordered] @{
                        officer_oid = $officer
                        storage = $sourceStorage
                        container = $domain.sourceContainer
                        blob = $blob.Name
                        version = $blob.VersionId
                        sha256 = Get-Sha256Hex $pdf
                    }
                    analyzer_id = $domain.analyzerId
                    analyzer_sha256 = $domain.analyzerSha256
                    analysis = $result
                }
                Set-BlobJson $evidence 'analysis-pending' $envelopeName $envelope
                $envelope = Get-BlobJson $evidence 'analysis-pending' $envelopeName
                Write-Output "Analyzed $officer/${key}: awaiting approval."
            }
            if ($blob.Tags[$approvalTag] -ne $approvedValue) { continue }
            if ($envelope.source.version -ne $blob.VersionId -or $envelope.source.container -ne $domain.sourceContainer -or
                $envelope.source.officer_oid -ne $officer -or $envelope.analyzer_sha256 -ne $domain.analyzerSha256) {
                throw 'Analysis envelope does not match the approved source version.'
            }
            $approvedKeys[$key] = $true
            $contentName = "$officer/$key.json"
            $existing = @(Get-BlobList $evidence 'approved-content' -Prefix $contentName -Include 'metadata' |
                Where-Object { $_.Name -eq $contentName })
            if ($existing.Count -eq 1 -and $existing[0].Metadata['regiqstate'] -eq 'approved') { continue }
            $approval = [ordered] @{
                approval_id = $key
                status = 'approved'
                mechanism = 'source-blob-index-tag'
                source = $envelope.source
                analyzer_sha256 = $envelope.analyzer_sha256
                analysis_sha256 = Get-TextSha256 (ConvertTo-StableJson $envelope)
                recorded_at = [DateTime]::UtcNow.ToString('o')
            }
            Set-BlobJson $evidence 'approval-ledger' "$officer/$key.json" $approval
            $records = New-EvidenceRecords $envelope $key
            Set-BlobJson $evidence 'approved-content' $contentName $records @{ regiqstate = 'approved' }
            $changed = $true
            Write-Output "Published $officer/${key}: $($records.Count) records."
        }
        foreach ($item in @(Get-BlobList $evidence 'approved-content' -Prefix "$officer/" -Include 'metadata')) {
            $key = [IO.Path]::GetFileNameWithoutExtension($item.Name)
            if ($approvedKeys.ContainsKey($key) -or $item.Metadata['regiqstate'] -eq 'withdrawn') { continue }
            $records = Get-BlobJson $evidence 'approved-content' $item.Name
            $tombstones = @($records | ForEach-Object {
                [ordered] @{ id = $_.id; title = 'withdrawn'; content = ''; approved = $false }
            })
            Set-BlobJson $evidence 'approved-content' $item.Name $tombstones @{ regiqstate = 'withdrawn' }
            Set-BlobJson $evidence 'approval-ledger' "$officer/$key.withdrawn.json" ([ordered] @{
                approval_id = $key; status = 'withdrawn'; recorded_at = [DateTime]::UtcNow.ToString('o')
            })
            $changed = $true
            Write-Output "Withdrew $officer/${key}: $($tombstones.Count) records."
        }
        if (-not $changed) {
            $status = Invoke-Private GET "https://$($domain.searchService).search.windows.net/indexers/approved-content/status?api-version=$searchApi"
            Assert-Status $status 200 'Indexer status'
            $last = ($status.Content | ConvertFrom-Json -AsHashtable -Depth 50).lastResult
            # Re-run when any approved or withdrawn record blob is newer than
            # the start of the last successful indexer run, so an earlier
            # interrupted run is always completed.
            $modified = @(Get-BlobList $evidence 'approved-content' -Prefix "$officer/" |
                ForEach-Object { $_.LastModified } | Sort-Object -Descending)
            $newest = if ($modified.Count -gt 0) { $modified[0] } else { $null }
            if ($null -ne $newest) {
                $changed = $null -eq $last -or $last.status -ne 'success' -or $null -eq $last.startTime -or
                    ([DateTime] $last.startTime).ToUniversalTime() -le $newest
            }
        }
        if ($changed) { Invoke-IndexerRun $domain }
        Write-Output "Reconciled ${officer}: $($sources.Count) current PDFs, $($approvedKeys.Count) approved."
    } catch {
        $failures++
        Write-Output "Ingestion failed for ${officer}: $($_.Exception.Message)"
    }
}
if ($shared) {
    foreach ($officerId in $bindings.Keys) {
        try {
            Invoke-SharedPipeline $officerId $bindings[$officerId]
        } catch {
            $failures++
            Write-Output "Shared ingestion failed for ${officerId}: $($_.Exception.Message)"
        }
    }
}
if ($failures -gt 0) { exit 1 }
Write-Output 'Ingestion reconcile finished.'
