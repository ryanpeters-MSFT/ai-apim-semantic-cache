param(
    [string]$location = 'centralus',
    [string]$group = 'rg-apim-semantic-cache',
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
    $resolvedSuffix = Get-ResolvedSuffix
    $apim = ("apim{0}" -f $resolvedSuffix).ToLower()
    $endpoint = "https://$apim.azure-api.net/openai/deployments/$chatDeployment/chat/completions?api-version=$apiVersion"

    return @{
        apim = $apim
        endpoint = $endpoint
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

    $maxAttempts = 4
    $elapsed = Measure-Command {
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $script:webResponse = Invoke-WebRequest -Method Post -Uri $context.endpoint -Headers @{
                    'Content-Type' = 'application/json'
                } -Body $body
                $script:response = $webResponse.Content | ConvertFrom-Json -Depth 20
                break
            }
            catch {
                $statusCode = $_.Exception.Response.StatusCode.value__
                if ($statusCode -ne 429 -or $attempt -eq $maxAttempts) {
                    throw
                }

                $retryAfterHeader = $_.Exception.Response.Headers['Retry-After']
                $retryAfterSeconds = 15
                if ($retryAfterHeader) {
                    [void][int]::TryParse($retryAfterHeader[0], [ref]$retryAfterSeconds)
                }

                Write-Host "throttled on attempt $attempt. retrying in $retryAfterSeconds seconds..."
                Start-Sleep -Seconds $retryAfterSeconds
            }
        }
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