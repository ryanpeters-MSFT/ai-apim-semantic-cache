param(
    [string]$location = 'centralus',
    [string]$group = 'rg-apim-semantic-cache',
    [string]$chatDeployment = 'chatdemo',
    [string]$apiVersion = '2024-02-01',
    [string]$prompt = 'Say hello in one short sentence.',
    [int]$maxTokens = 60
)

$ErrorActionPreference = 'Stop'

function Get-ResolvedSuffix {
    $subscriptionId = az account show --query id -o tsv
    $locationKey = ($location -replace '[^a-zA-Z]', '').ToLower()
    if ($locationKey.Length -gt 3) {
        $locationKey = $locationKey.Substring(0, 3)
    }

    return "$locationKey$((($subscriptionId -replace '-', '').Substring(0, 6)).ToLower())"
}

function Get-RequestContext {
    $resolvedSuffix = Get-ResolvedSuffix
    $apim = ("apim{0}" -f $resolvedSuffix).ToLower()
    $endpoint = "https://$apim.azure-api.net/openai/deployments/$chatDeployment/chat/completions?api-version=$apiVersion"

    return @{
        endpoint = $endpoint
    }
}

$context = Get-RequestContext
$body = @{
    messages = @(
        @{
            role = 'user'
            content = $prompt
        }
    )
    temperature = 0
    max_tokens = $maxTokens
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod -Method Post -Uri $context.endpoint -Headers @{
    'Content-Type' = 'application/json'
} -Body $body

Write-Host "endpoint: $($context.endpoint)"
Write-Host "prompt: $prompt"
Write-Host 'response:'
Write-Host $response.choices[0].message.content