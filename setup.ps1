param(
    [string]$suffix,
    [string]$location = 'centralus',
    [string]$group = 'rg-apim-semantic-cache',
    [string]$publisherName = 'Contoso',
    [string]$chatModelName = 'gpt-4.1-mini',
    [string]$chatModelVersion = '2025-04-14',
    [string]$chatDeployment = 'chatdemo',
    [int]$chatCapacity = 30,
    [string]$embeddingsModelName = 'text-embedding-3-small',
    [string]$embeddingsModelVersion = '1',
    [string]$embeddingsDeployment = 'embeddingsdemo',
    [int]$embeddingsCapacity = 30,
    [string]$redisSku = 'Balanced_B0',
    [int]$redisCapacity = 2,
    [string]$apimSku = 'Developer'
)

$specPath = 'apim\openai-chat-api.json'
$policyPath = 'apim\semantic-cache-policy.xml'

$subscriptionId = az account show --query id -o tsv

$resolvedSuffix = $suffix
if ([string]::IsNullOrWhiteSpace($resolvedSuffix)) {
    $characters = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
    $resolvedSuffix = -join (1..6 | ForEach-Object { $characters[(Get-Random -Maximum $characters.Length)] })
}

$openAi = "foundry$resolvedSuffix"
$apim = "apim$resolvedSuffix"
$redis = "redis$resolvedSuffix"
$appInsights = "appi$resolvedSuffix"
$apiId = 'openai-chat'
$chatBackendId = 'openai-backend'
$backendId = 'embeddings-backend'
$loggerId = 'applicationinsights'
$diagnosticId = 'applicationinsights'

$redisCapacityArg = @()
if ($redisSku -like 'Enterprise_*' -or $redisSku -like 'EnterpriseFlash_*') {
    $redisCapacityArg = @('--capacity', $redisCapacity)
}
$redisApiVersion = '2025-08-01-preview'
$redisClusterId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Cache/redisEnterprise/$redis"
$redisDatabaseId = "$redisClusterId/databases/default"

# create the resource group
az group create -n $group -l $location -o none

# create the foundry openai resource
az cognitiveservices account create -n $openAi -g $group --kind OpenAI --sku S0 -l $location --custom-domain $openAi --yes -o none

# get publisher email for APIM
$publisherEmail = az account show --query user.name -o tsv

# create application insights for APIM diagnostics
$appInsightsExists = ((az monitor app-insights component show -a $appInsights -g $group --query id -o tsv 2>$null | Out-String).Trim().Length -gt 0)
if (-not $appInsightsExists) {
    az monitor app-insights component create -a $appInsights -g $group -l $location --kind web --application-type web --retention-time 30 -o none
}

# create the chat deployment
az cognitiveservices account deployment create -g $group -n $openAi --deployment-name $chatDeployment --model-name $chatModelName --model-version $chatModelVersion --model-format OpenAI --sku-capacity $chatCapacity --sku-name GlobalStandard -o none

# create the embeddings deployment
az cognitiveservices account deployment create -g $group -n $openAi --deployment-name $embeddingsDeployment --model-name $embeddingsModelName --model-version $embeddingsModelVersion --model-format OpenAI --sku-capacity $embeddingsCapacity --sku-name GlobalStandard -o none

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
    az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Cache/redisEnterprise/${redis}?api-version=$redisApiVersion" --body "@$redisClusterBodyPath" -o none
}

az resource wait --ids $redisClusterId --api-version $redisApiVersion --custom "properties.resourceState=='Running'" --interval 15 --timeout 1800 --only-show-errors

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
    az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.Cache/redisEnterprise/$redis/databases/default?api-version=$redisApiVersion" --body "@$redisDatabaseBodyPath" -o none
}

az resource wait --ids $redisDatabaseId --api-version $redisApiVersion --custom "properties.resourceState=='Running'" --interval 15 --timeout 1800 --only-show-errors

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
az apim create -n $apim -g $group -l $location --sku-name $apimSku --publisher-email $publisherEmail --publisher-name $publisherName --enable-managed-identity true -o none

$apimPrincipalId = az apim show -g $group -n $apim --query identity.principalId -o tsv

# grant apim access to azure openai
az role assignment create --assignee-object-id $apimPrincipalId --assignee-principal-type ServicePrincipal --role "Cognitive Services OpenAI User" --scope $openAiId -o none

# add the chat backend
$chatBackendBody = @{
    properties = @{
        description = 'chat backend for semantic cache demo'
        url = "$openAiEndpoint/openai"
        protocol = 'http'
        credentials = @{
            managedIdentity = @{
                resource = 'https://cognitiveservices.azure.com'
            }
        }
    }
} | ConvertTo-Json -Depth 10

$chatBackendBodyPath = Join-Path $env:TEMP 'apim-chat-backend.json'
$chatBackendBody | Set-Content -Path $chatBackendBodyPath -NoNewline

az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/backends/${chatBackendId}?api-version=2024-05-01" --body "@$chatBackendBodyPath" -o none

# add the embeddings backend
az apim backend create --service-name $apim -g $group --backend-id $backendId --protocol http --url "$openAiEndpoint/openai/deployments/$embeddingsDeployment/embeddings" --description "embeddings backend for semantic cache" -o none

# import the chat api
az apim api import --service-name $apim -g $group --api-id $apiId --path openai --display-name "OpenAI Chat Demo" --specification-format OpenApiJson --specification-path $specPath --service-url "$openAiEndpoint/openai" --subscription-required false -o none

# configure application insights logger for APIM
$loggerBody = @{
    properties = @{
        loggerType = 'applicationInsights'
        description = 'application insights logger for semantic cache demo'
        isBuffered = $true
        credentials = @{
            instrumentationKey = $appInsightsInstrumentationKey
        }
        resourceId = $appInsightsId
    }
} | ConvertTo-Json -Depth 10

$loggerBodyPath = Join-Path $env:TEMP 'apim-logger.json'
$loggerBody | Set-Content -Path $loggerBodyPath -NoNewline

az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/loggers/${loggerId}?api-version=2024-05-01" --body "@$loggerBodyPath" -o none

# enable API diagnostics to send frontend and backend telemetry to application insights
$diagnosticBody = @{
    properties = @{
        loggerId = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/loggers/$loggerId"
        alwaysLog = 'allErrors'
        httpCorrelationProtocol = 'W3C'
        logClientIp = $true
        verbosity = 'information'
        sampling = @{
            samplingType = 'fixed'
            percentage = 100
        }
        frontend = @{
            request = @{
                headers = @('Content-Type')
                body = @{
                    bytes = 8192
                }
            }
            response = @{
                headers = @('Content-Type')
                body = @{
                    bytes = 0
                }
            }
        }
        backend = @{
            request = @{
                headers = @('Content-Type')
                body = @{
                    bytes = 8192
                }
            }
            response = @{
                headers = @('Content-Type')
                body = @{
                    bytes = 0
                }
            }
        }
    }
} | ConvertTo-Json -Depth 10

$diagnosticBodyPath = Join-Path $env:TEMP 'apim-diagnostic.json'
$diagnosticBody | Set-Content -Path $diagnosticBodyPath -NoNewline

az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/apis/$apiId/diagnostics/${diagnosticId}?api-version=2024-05-01" --body "@$diagnosticBodyPath" -o none

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

az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/caches/default?api-version=2022-08-01" --body "@$cacheBodyPath" -o none

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

az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/apis/$apiId/policies/policy?api-version=2017-03-01" --body "@$policyBodyPath" --output-file $policyResponsePath -o none

Remove-Item $chatBackendBodyPath,$loggerBodyPath,$diagnosticBodyPath,$cacheBodyPath,$policyBodyPath,$policyResponsePath -ErrorAction SilentlyContinue

Write-Host "group: $group"
Write-Host "apim: https://$apim.azure-api.net/openai/deployments/$chatDeployment/chat/completions?api-version=2024-02-01"
Write-Host "openai: $openAiEndpoint"
Write-Host "redis: $redisHost`:$redisPort"
Write-Host "appInsights: $appInsights"
Write-Host "suffix: $resolvedSuffix"
