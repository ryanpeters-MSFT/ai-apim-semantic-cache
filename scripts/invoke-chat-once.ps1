param(
    [string]$suffix,
    [string]$chatDeployment = 'chatdemo',
    [string]$apiVersion = '2024-02-01',
    [string]$prompt = 'Say hello in one short sentence.',
    [int]$maxTokens = 60
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($suffix)) {
    throw 'suffix is required.'
}

$endpoint = "https://apim$suffix.azure-api.net/openai/deployments/$chatDeployment/chat/completions?api-version=$apiVersion"
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

$response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers @{
    'Content-Type' = 'application/json'
} -Body $body

Write-Host "response: $($response.choices[0].message.content)"