param(
    [string]$suffix = 'demo01',
    [string]$location = 'centralus',
    [string]$group = 'rg-apim-semantic-cache',
    [string]$publisherEmail = 'ryanpeters@microsoft.com',
    [string]$publisherName = 'Contoso',
    [string]$chatModelName = 'gpt-4.1-mini',
    [string]$chatModelVersion = '2025-04-14',
    [string]$chatDeployment = 'chatdemo',
    [string]$embeddingsModelName = 'text-embedding-3-small',
    [string]$embeddingsModelVersion = '1',
    [string]$embeddingsDeployment = 'embeddingsdemo',
    [string]$redisSku = 'Balanced_B0',
    [int]$redisCapacity = 2,
    [string]$apimSku = 'Consumption'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$specPath = Join-Path $root 'apim\openai-chat-api.json'
$policyPath = Join-Path $root 'apim\semantic-cache-policy.xml'
$queryPath = Join-Path $root 'queries\semantic-cache-hit-miss.kql'
$subscriptionId = az account show --query id -o tsv
$resolvedSuffix = $suffix
if ($resolvedSuffix -eq 'demo01') {
    $locationKey = ($location -replace '[^a-zA-Z]', '').ToLower()
    if ($locationKey.Length -gt 3) {
        $locationKey = $locationKey.Substring(0, 3)
    }
    $resolvedSuffix = "$locationKey$((($subscriptionId -replace '-', '').Substring(0, 6)).ToLower())"
}

$openAi = ("foundry{0}" -f $resolvedSuffix).ToLower()
$apim = ("apim{0}" -f $resolvedSuffix).ToLower()
$redis = ("redis{0}" -f $resolvedSuffix).ToLower()
$appInsights = ("appi{0}" -f $resolvedSuffix).ToLower()
$apiId = 'openai-chat'
$backendId = 'embeddings-backend'
$loggerId = 'applicationinsights'
$diagnosticId = 'applicationinsights'
$conflictPattern = 'already exists|Conflict|already in use|cannot be updated because it already exists'
$redisCapacityArg = @()
if ($redisSku -like 'Enterprise_*' -or $redisSku -like 'EnterpriseFlash_*') {
    $redisCapacityArg = @('--capacity', $redisCapacity)
}
$redisApiVersion = '2025-08-01-preview'
$redisClusterId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Cache/redisEnterprise/$redis"
$redisDatabaseId = "$redisClusterId/databases/default"

function Wait-RedisResourceState {
    param(
        [string]$resourceId,
        [string]$targetState = 'Running'
    )

    for ($i = 0; $i -lt 120; $i++) {
        $state = (az resource show --ids $resourceId --api-version $redisApiVersion --query properties.resourceState -o tsv 2>$null | Out-String).Trim()
        if ($state -eq $targetState) { return }
        if ($state -like '*Failed') { throw "Redis resource $resourceId entered state $state." }
        Start-Sleep -Seconds 15
    }

    throw "Timed out waiting for Redis resource $resourceId to reach state $targetState."
}

# create the resource group
$message = (az group create -n $group -l $location -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# create the foundry openai resource
$message = (az cognitiveservices account create -n $openAi -g $group --kind OpenAI --sku S0 -l $location --custom-domain $openAi --yes -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# create application insights for APIM diagnostics
$appInsightsExists = ((az monitor app-insights component show -a $appInsights -g $group --query id -o tsv 2>$null | Out-String).Trim().Length -gt 0)
if (-not $appInsightsExists) {
    $message = (az monitor app-insights component create -a $appInsights -g $group -l $location --kind web --application-type web --retention-time 30 -o none 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
    if ($LASTEXITCODE -ne 0) { Write-Host $message }
}

# create the chat deployment
$message = (az cognitiveservices account deployment create -g $group -n $openAi --deployment-name $chatDeployment --model-name $chatModelName --model-version $chatModelVersion --model-format OpenAI --sku-capacity 1 --sku-name GlobalStandard -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# create the embeddings deployment
$message = (az cognitiveservices account deployment create -g $group -n $openAi --deployment-name $embeddingsDeployment --model-name $embeddingsModelName --model-version $embeddingsModelVersion --model-format OpenAI --sku-capacity 1 --sku-name GlobalStandard -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# create managed redis cluster
$redisClusterBody = @{
    location = $location
    kind = 'v2'
    sku = @{
        name = $redisSku
    }
    properties = @{
        highAvailability = 'Disabled'
        minimumTlsVersion = '1.2'
        publicNetworkAccess = 'Enabled'
    }
} | ConvertTo-Json -Depth 10

$redisClusterBodyPath = Join-Path $env:TEMP "$redis-cluster.json"
$redisClusterBody | Set-Content -Path $redisClusterBodyPath -NoNewline

$redisClusterExists = ((az resource show --ids $redisClusterId --api-version $redisApiVersion --query id -o tsv 2>$null | Out-String).Trim().Length -gt 0)
if (-not $redisClusterExists) {
    $message = (az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Cache/redisEnterprise/${redis}?api-version=$redisApiVersion" --body "@$redisClusterBodyPath" -o none 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
    if ($LASTEXITCODE -ne 0) { Write-Host $message }
}

Wait-RedisResourceState -resourceId $redisClusterId

# create the default managed redis database with redisearch
$redisDatabaseBody = @{
    properties = @{
        accessKeysAuthentication = 'Enabled'
        clientProtocol = 'Encrypted'
        clusteringPolicy = 'EnterpriseCluster'
        evictionPolicy = 'NoEviction'
        modules = @(
            @{
                name = 'RediSearch'
            }
        )
    }
} | ConvertTo-Json -Depth 10

$redisDatabaseBodyPath = Join-Path $env:TEMP "$redis-database.json"
$redisDatabaseBody | Set-Content -Path $redisDatabaseBodyPath -NoNewline

$redisDatabaseExists = ((az resource show --ids $redisDatabaseId --api-version $redisApiVersion --query id -o tsv 2>$null | Out-String).Trim().Length -gt 0)
if (-not $redisDatabaseExists) {
    $message = (az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Cache/redisEnterprise/$redis/databases/default?api-version=$redisApiVersion" --body "@$redisDatabaseBodyPath" -o none 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
    if ($LASTEXITCODE -ne 0) { Write-Host $message }
}

Wait-RedisResourceState -resourceId $redisDatabaseId

Remove-Item $redisClusterBodyPath,$redisDatabaseBodyPath -ErrorAction SilentlyContinue

$redisHost = az resource show --ids $redisClusterId --api-version $redisApiVersion --query properties.hostName -o tsv
$redisPort = az resource show --ids $redisDatabaseId --api-version $redisApiVersion --query properties.port -o tsv
$redisKey = az redisenterprise database list-keys -g $group --cluster-name $redis --query primaryKey -o tsv
$redisId = az resource show --ids $redisClusterId --api-version $redisApiVersion --query id -o tsv
$openAiEndpoint = (az cognitiveservices account show -g $group -n $openAi --query properties.endpoint -o tsv).TrimEnd('/')
$openAiId = az cognitiveservices account show -g $group -n $openAi --query id -o tsv
$appInsightsId = az monitor app-insights component show -a $appInsights -g $group --query id -o tsv
$appInsightsInstrumentationKey = az monitor app-insights component show -a $appInsights -g $group --query instrumentationKey -o tsv

# create apim with managed identity
$message = (az apim create -n $apim -g $group -l $location --sku-name $apimSku --publisher-email $publisherEmail --publisher-name $publisherName --enable-managed-identity true -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

$apimPrincipalId = az apim show -g $group -n $apim --query identity.principalId -o tsv

# grant apim access to azure openai
$message = (az role assignment create --assignee-object-id $apimPrincipalId --assignee-principal-type ServicePrincipal --role 'Cognitive Services OpenAI User' --scope $openAiId -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# add the embeddings backend
$message = (az apim backend create --service-name $apim -g $group --backend-id $backendId --protocol http --url "$openAiEndpoint/openai/deployments/$embeddingsDeployment/embeddings" --description 'embeddings backend for semantic cache' -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# import the chat api
$message = (az apim api import --service-name $apim -g $group --api-id $apiId --path openai --display-name 'OpenAI Chat Demo' --specification-format OpenApiJson --specification-path $specPath --service-url "$openAiEndpoint/openai" --subscription-required true -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# configure application insights logger for APIM
$loggerBody = @{
    properties = @{
        loggerType = 'applicationInsights'
        description = 'application insights logger for semantic cache demo'
        credentials = @{
            instrumentationKey = $appInsightsInstrumentationKey
        }
        resourceId = $appInsightsId
    }
} | ConvertTo-Json -Depth 10

$loggerBodyPath = Join-Path $env:TEMP 'apim-logger.json'
$loggerBody | Set-Content -Path $loggerBodyPath -NoNewline

$message = (az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/loggers/${loggerId}?api-version=2024-05-01" --body "@$loggerBodyPath" -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# enable API diagnostics to send frontend and backend telemetry to application insights
$diagnosticBody = @{
    properties = @{
        loggerId = "/loggers/$loggerId"
        alwaysLog = 'allErrors'
        httpCorrelationProtocol = 'W3C'
        sampling = @{
            samplingType = 'fixed'
            percentage = 100
        }
        frontend = @{
            request = @{
                headers = @('Content-Type')
            }
            response = @{
                headers = @('Content-Type')
            }
        }
        backend = @{
            request = @{
                headers = @('Content-Type')
            }
            response = @{
                headers = @('Content-Type')
            }
        }
    }
} | ConvertTo-Json -Depth 10

$diagnosticBodyPath = Join-Path $env:TEMP 'apim-diagnostic.json'
$diagnosticBody | Set-Content -Path $diagnosticBodyPath -NoNewline

$message = (az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/apis/$apiId/diagnostics/${diagnosticId}?api-version=2024-05-01" --body "@$diagnosticBodyPath" -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# configure apim to use redis as the external cache
$cacheBody = @{
    properties = @{
        connectionString = "$redisHost`:$redisPort,password=$redisKey,ssl=True,abortConnect=False"
        useFromLocation = 'default'
        description = 'redis enterprise semantic cache'
        resourceId = "https://management.azure.com$redisId"
    }
} | ConvertTo-Json -Depth 10

$cacheBodyPath = Join-Path $env:TEMP "$apim-cache.json"
$cacheBody | Set-Content -Path $cacheBodyPath -NoNewline

$message = (az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/caches/default?api-version=2022-08-01" --body "@$cacheBodyPath" -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# publish the semantic cache policy
$policyContent = (Get-Content -Raw $policyPath).TrimStart([char]0xfeff)
$policyBody = @{
    properties = @{
        policyContent = $policyContent
    }
} | ConvertTo-Json -Depth 10

$policyBodyPath = Join-Path $env:TEMP "$apim-policy.json"
$policyBody | Set-Content -Path $policyBodyPath -NoNewline
$policyResponsePath = Join-Path $env:TEMP "$apim-policy-response.txt"

$message = (az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/apis/$apiId/policies/policy?api-version=2017-03-01" --body "@$policyBodyPath" --output-file $policyResponsePath -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

$queryContent = @"
let apiPath = '/openai/deployments/$chatDeployment/chat/completions';
let chatDependencyPath = '/openai/deployments/$chatDeployment/chat/completions';
let embeddingsDependencyPath = '/openai/deployments/$embeddingsDeployment/embeddings';

// classify each APIM request as a semantic cache hit or miss
let dependencyFlags = AppDependencies
| where TimeGenerated > ago(1d)
| summarize
    hasChatDependency = countif(Data has chatDependencyPath or Name has chatDependencyPath) > 0,
    hasEmbeddingsDependency = countif(Data has embeddingsDependencyPath or Name has embeddingsDependencyPath) > 0,
    dependencyCount = count()
    by OperationId;

AppRequests
| where TimeGenerated > ago(1d)
| where Url has apiPath
| join kind=leftouter dependencyFlags on OperationId
| extend cacheResult = iff(coalesce(hasChatDependency, false), 'miss', iff(coalesce(hasEmbeddingsDependency, false), 'hit', 'unknown'))
| project TimeGenerated, Name, Url, DurationMs, ResultCode, Success, cacheResult, dependencyCount, OperationId
| order by TimeGenerated desc

// summarize hit and miss counts over time
AppRequests
| where TimeGenerated > ago(1d)
| where Url has apiPath
| join kind=leftouter dependencyFlags on OperationId
| extend cacheResult = iff(coalesce(hasChatDependency, false), 'miss', iff(coalesce(hasEmbeddingsDependency, false), 'hit', 'unknown'))
| summarize requests=count(), avgDurationMs=avg(DurationMs) by cacheResult, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
"@

$queryDir = Split-Path -Parent $queryPath
if (-not (Test-Path $queryDir)) {
    New-Item -ItemType Directory -Path $queryDir -Force | Out-Null
}
$queryContent | Set-Content -Path $queryPath -NoNewline

Remove-Item $loggerBodyPath,$diagnosticBodyPath,$cacheBodyPath,$policyBodyPath,$policyResponsePath -ErrorAction SilentlyContinue

Write-Host "group: $group"
Write-Host "apim: https://$apim.azure-api.net/openai/deployments/$chatDeployment/chat/completions?api-version=2024-02-01"
Write-Host "openai: $openAiEndpoint"
Write-Host "redis: $redisHost`:$redisPort"
Write-Host "appInsights: $appInsights"
Write-Host "queries: $queryPath"
