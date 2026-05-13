param(
    [string]$suffix,
    [string]$group = 'rg-apim-semantic-cache',
    [string]$chatDeployment = 'chatdemo',
    [string]$timespan = 'P1D',
    [string]$timeZone = 'Eastern Standard Time',
    [ValidateSet('all', 'recent', 'summary')]
    [string]$view = 'all'
)

$appInsights = "appi$suffix"

$resolvedTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($timeZone)

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }

    if (-not $output) {
        return $null
    }

    $output | ConvertFrom-Json -DateKind String
}

function Invoke-AzCliText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }

    if ($null -eq $output) {
        return $null
    }

    ($output | Out-String).Trim()
}

$workspaceResourceId = Invoke-AzCliText -Arguments @('monitor', 'app-insights', 'component', 'show', '-a', $appInsights, '-g', $group, '--query', 'workspaceResourceId', '-o', 'tsv')
if (-not $workspaceResourceId) {
    throw "Workspace resource ID was not found for Application Insights '$appInsights'."
}

$workspaceGuid = Invoke-AzCliText -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '--ids', $workspaceResourceId, '--query', 'customerId', '-o', 'tsv')
if (-not $workspaceGuid) {
    throw "Workspace GUID was not found for Application Insights '$appInsights'."
}

$recentQuery = @"
AppRequests
| where TimeGenerated > ago(1d)
| where Url has '/openai/deployments/$chatDeployment/chat/completions'
| order by TimeGenerated desc
| take 20
"@

$summaryQuery = @"
AppRequests
| where TimeGenerated > ago(1d)
| where Url has '/openai/deployments/$chatDeployment/chat/completions'
| order by TimeGenerated desc
"@

Write-Host "appInsights: $appInsights"
Write-Host "workspaceGuid: $workspaceGuid"
Write-Host "timespan: $timespan"
Write-Host ''

if ($view -in @('all', 'recent')) {
    Write-Host 'recent requests:'
    $recentResults = Invoke-AzCliJson -Arguments @('monitor', 'log-analytics', 'query', '-w', $workspaceGuid, '--analytics-query', $recentQuery, '-t', $timespan, '-o', 'json')
    $recentRows = foreach ($row in $recentResults) {
        $cache = ''
        if ($row.Properties) {
            try {
                $props = $row.Properties | ConvertFrom-Json
                $cache = $props.Cache
            }
            catch {
                $cache = ''
            }
        }

        $utcTime = [datetime]::Parse(
            $row.TimeGenerated,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
        $localTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcTime, $resolvedTimeZone)

        [pscustomobject]@{
            SortTime = $utcTime
            Time = $localTime.ToString('yyyy-MM-dd HH:mm:ss')
            Id = $row.Id
            Success = $row.Success
            Cache = $cache
            Request = ([uri]$row.Url).PathAndQuery
        }
    }
    $recentColumns = @(
        @{ Name = "Time"; Expression = { $_.Time } },
        @{ Name = 'Id'; Expression = { $_.Id } },
        @{ Name = 'Success'; Expression = { $_.Success } },
        @{ Name = 'Cache'; Expression = { $_.Cache } },
        @{ Name = 'Request'; Expression = { $_.Request } }
    )
    $recentRows |
        Sort-Object SortTime -Descending |
        Select-Object -First 20 |
        Sort-Object SortTime |
        Format-Table -Property $recentColumns -Wrap
    Write-Host ''
}

if ($view -in @('all', 'summary')) {
    Write-Host 'cache summary:'
    $summaryResults = Invoke-AzCliJson -Arguments @('monitor', 'log-analytics', 'query', '-w', $workspaceGuid, '--analytics-query', $summaryQuery, '-t', $timespan, '-o', 'json')
    $summaryGroups = $summaryResults | ForEach-Object {
        $cache = ''
        if ($_.Properties) {
            try {
                $props = $_.Properties | ConvertFrom-Json
                $cache = $props.Cache
            }
            catch {
                $cache = ''
            }
        }

        [pscustomobject]@{
            Cache = $cache
            Success = [System.Convert]::ToBoolean($_.Success)
        }
    } | Group-Object Cache | ForEach-Object {
        [pscustomobject]@{
            Cache = if ($_.Name) { $_.Name } else { '' }
            requests = $_.Count
            successCount = ($_.Group | Where-Object { $_.Success }).Count
            failureCount = ($_.Group | Where-Object { -not $_.Success }).Count
        }
    } | Sort-Object Cache
    $summaryColumns = @(
        @{ Name = 'Cache'; Expression = { $_.Cache } },
        @{ Name = 'Requests'; Expression = { $_.requests } },
        @{ Name = 'Success'; Expression = { $_.successCount } },
        @{ Name = 'Failure'; Expression = { $_.failureCount } }
    )
    $summaryGroups | Format-Table -Property $summaryColumns -AutoSize
}