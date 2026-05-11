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

$params = @{
    suffix = $suffix
    location = $location
    group = $group
    publisherEmail = $publisherEmail
    publisherName = $publisherName
    chatModelName = $chatModelName
    chatModelVersion = $chatModelVersion
    chatDeployment = $chatDeployment
    embeddingsModelName = $embeddingsModelName
    embeddingsModelVersion = $embeddingsModelVersion
    embeddingsDeployment = $embeddingsDeployment
    redisSku = $redisSku
    redisCapacity = $redisCapacity
    apimSku = $apimSku
}

& "$PSScriptRoot\scripts\deploy-demo.ps1" @params

exit $LASTEXITCODE