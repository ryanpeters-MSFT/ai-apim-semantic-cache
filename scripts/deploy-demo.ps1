param(
    [string]$suffix = 'demo01',
    [string]$location = 'eastus2',
    [string]$group = 'rg-apim-semantic-cache',
    [string]$publisherEmail = 'ryanpeters@microsoft.com',
    [string]$publisherName = 'Contoso',
    [string]$chatModelName = 'gpt-4.1-mini',
    [string]$chatModelVersion = '2025-04-14',
    [string]$chatDeployment = 'chatdemo',
    [string]$embeddingsModelName = 'text-embedding-3-small',
    [string]$embeddingsModelVersion = '1',
    [string]$embeddingsDeployment = 'embeddingsdemo',
    [string]$redisSku = 'Enterprise_E1',
    [int]$redisCapacity = 2,
    [string]$apimSku = 'Consumption'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$specPath = Join-Path $root 'apim\openai-chat-api.json'
$policyPath = Join-Path $root 'apim\semantic-cache-policy.xml'
$subscriptionId = az account show --query id -o tsv
$resolvedSuffix = $suffix
if ($resolvedSuffix -eq 'demo01') {
    $resolvedSuffix = "demo$((($subscriptionId -replace '-', '').Substring(0, 6)).ToLower())"
}

$openAi = ("foundry{0}" -f $resolvedSuffix).ToLower()
$apim = ("apim{0}" -f $resolvedSuffix).ToLower()
$redis = ("redis{0}" -f $resolvedSuffix).ToLower()
$apiId = 'openai-chat'
$backendId = 'embeddings-backend'
$conflictPattern = 'already exists|Conflict|already in use|cannot be updated because it already exists'

# create the resource group
$message = (az group create -n $group -l $location -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# create the foundry openai resource
$message = (az cognitiveservices account create -n $openAi -g $group --kind OpenAI --sku S0 -l $location --custom-domain $openAi --yes -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# create the chat deployment
$message = (az cognitiveservices account deployment create -g $group -n $openAi --deployment-name $chatDeployment --model-name $chatModelName --model-version $chatModelVersion --model-format OpenAI --sku-capacity 1 --sku-name Standard -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# create the embeddings deployment
$message = (az cognitiveservices account deployment create -g $group -n $openAi --deployment-name $embeddingsDeployment --model-name $embeddingsModelName --model-version $embeddingsModelVersion --model-format OpenAI --sku-capacity 1 --sku-name Standard -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# create redis enterprise with redisearch enabled
$message = (az redisenterprise create -g $group -n $redis -l $location --sku $redisSku --capacity $redisCapacity --minimum-tls-version 1.2 --public-network-access Enabled --access-keys-auth Enabled --modules name=RediSearch -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

$redisHost = az redisenterprise show -g $group -n $redis --query properties.hostName -o tsv
$redisPort = az redisenterprise database show -g $group --cluster-name $redis --query properties.port -o tsv
$redisKey = az redisenterprise database list-keys -g $group --cluster-name $redis --query primaryKey -o tsv
$redisId = az redisenterprise show -g $group -n $redis --query id -o tsv
$openAiEndpoint = (az cognitiveservices account show -g $group -n $openAi --query properties.endpoint -o tsv).TrimEnd('/')
$openAiId = az cognitiveservices account show -g $group -n $openAi --query id -o tsv

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

# configure apim to use redis as the external cache
$cacheBody = @{
    properties = @{
        connectionString = "$redisHost`:$redisPort,password=$redisKey,ssl=True,abortConnect=False"
        useFromLocation = 'default'
        description = 'redis enterprise semantic cache'
        resourceId = $redisId
    }
} | ConvertTo-Json -Depth 10

$message = (az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/caches/default?api-version=2022-08-01" --body $cacheBody --headers Content-Type=application/json -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

# publish the semantic cache policy
$policyBody = @{
    properties = @{
        policyContent = (Get-Content -Raw $policyPath)
    }
} | ConvertTo-Json -Depth 10

$message = (az rest --method put --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/apis/$apiId/policies/policy?api-version=2017-03-01" --body $policyBody --headers Content-Type=application/json -o none 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -and $message -notmatch $conflictPattern) { throw $message }
if ($LASTEXITCODE -ne 0) { Write-Host $message }

Write-Host "group: $group"
Write-Host "apim: https://$apim.azure-api.net/openai/deployments/$chatDeployment/chat/completions?api-version=2024-02-01"
Write-Host "openai: $openAiEndpoint"
Write-Host "redis: $redisHost`:$redisPort"
