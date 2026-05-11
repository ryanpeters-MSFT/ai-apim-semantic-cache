param(
    [string]$location = 'centralus',
    [string]$group = 'rg-apim-semantic-cache',
    [string]$subscriptionName = 'Built-in all-access subscription',
    [string]$chatDeployment = 'chatdemo',
    [string]$apiVersion = '2024-02-01',
    [string]$selection
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

function Get-TestContext {
    $subscriptionId = az account show --query id -o tsv
    $resolvedSuffix = Get-ResolvedSuffix
    $apim = ("apim{0}" -f $resolvedSuffix).ToLower()
    $subscriptionListUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/subscriptions?api-version=2022-08-01"
    $apimSubscriptionId = az rest --method get --uri $subscriptionListUri --query "value[?properties.displayName=='$subscriptionName'].name | [0]" -o tsv
    if (-not $apimSubscriptionId) {
        throw "APIM subscription '$subscriptionName' was not found on service '$apim'."
    }

    $subscriptionSecretUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.ApiManagement/service/$apim/subscriptions/$apimSubscriptionId/listSecrets?api-version=2022-08-01"
    $subscriptionKey = az rest --method post --uri $subscriptionSecretUri --query primaryKey -o tsv
    $endpoint = "https://$apim.azure-api.net/openai/deployments/$chatDeployment/chat/completions?api-version=$apiVersion"

    return @{
        apim = $apim
        endpoint = $endpoint
        subscriptionId = $apimSubscriptionId
        subscriptionKey = $subscriptionKey
    }
}

function Invoke-TestRequest {
    param(
        [string]$prompt,
        [string]$label
    )

    $context = Get-TestContext
    $body = @{
        messages = @(
            @{
                role = 'user'
                content = $prompt
            }
        )
        temperature = 0
        max_tokens = 120
    } | ConvertTo-Json -Depth 10

    $elapsed = Measure-Command {
        $script:webResponse = Invoke-WebRequest -Method Post -Uri $context.endpoint -Headers @{
            'Ocp-Apim-Subscription-Key' = $context.subscriptionKey
            'Content-Type' = 'application/json'
        } -Body $body
        $script:response = $webResponse.Content | ConvertFrom-Json -Depth 20
    }

    $cacheStatus = $webResponse.Headers['x-semantic-cache']

    Write-Host "label: $label"
    Write-Host "endpoint: $($context.endpoint)"
    Write-Host "elapsedMs: $([math]::Round($elapsed.TotalMilliseconds, 2))"
    Write-Host "cacheStatus: $cacheStatus"
    Write-Host "response:"
    Write-Host $response.choices[0].message.content
    Write-Host ''
}

function Show-Config {
    $context = Get-TestContext
    Write-Host "group: $group"
    Write-Host "apim: $($context.apim)"
    Write-Host "endpoint: $($context.endpoint)"
    Write-Host "subscriptionId: $($context.subscriptionId)"
    Write-Host ''
}

function Invoke-ExactCall1 {
    Invoke-TestRequest -label 'exact-1' -prompt 'In one short paragraph, explain what semantic caching is.'
}

function Invoke-ExactCall2 {
    Invoke-TestRequest -label 'exact-2' -prompt 'In one short paragraph, explain what semantic caching is.'
}

function Invoke-SimilarCall {
    Invoke-TestRequest -label 'similar' -prompt 'Briefly describe how a semantic cache works for LLM requests.'
}

function Invoke-AllTests {
    Show-Config
    Invoke-ExactCall1
    Invoke-ExactCall2
    Invoke-SimilarCall
}

function Invoke-MenuSelection {
    param([string]$choice)

    switch ($choice) {
        '1' { Show-Config }
        '2' { Invoke-ExactCall1 }
        '3' { Invoke-ExactCall2 }
        '4' { Invoke-SimilarCall }
        '5' { Invoke-AllTests }
        'q' { return $false }
        'Q' { return $false }
        default { Write-Host 'Invalid selection.' }
    }

    return $true
}

if ($selection) {
    [void](Invoke-MenuSelection -choice $selection)
    exit 0
}

while ($true) {
    Write-Host '1. Show config'
    Write-Host '2. First exact prompt'
    Write-Host '3. Second exact prompt'
    Write-Host '4. Similar prompt'
    Write-Host '5. Run all tests'
    Write-Host 'Q. Quit'
    $choice = Read-Host 'Choose an option'
    if (-not (Invoke-MenuSelection -choice $choice)) {
        break
    }
}