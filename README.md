# APIM with OpenAI and Semantic Cache

This repo contains a simple PowerShell deployment script that uses Azure CLI to create:

- an API Management instance
- an Azure OpenAI in Foundry resource with one chat deployment and one embeddings deployment
- a Redis Enterprise cluster with RediSearch enabled
- an Application Insights resource for APIM diagnostics
- an APIM API and policy that uses Redis as a semantic cache for chat completions

## Run

```powershell
.\setup.ps1 -group "rg-apim-semantic-cache" -chatDeployment "chatdemo" -embeddingsDeployment "embeddingsdemo" -suffix "bnrydad"
```

If you omit `-suffix`, `setup.ps1` generates a random 6-character lowercase suffix and uses it for the Foundry, APIM, Redis, and Application Insights resource names.

Example with current defaults:

```powershell
.\setup.ps1
```

## Notes

- the default location is `centralus`
- the default resource group is `rg-apim-semantic-cache`
- the default APIM SKU is `Developer`
- the default `publisherName` is `Contoso`
- `publisherEmail` is taken from the currently logged-in Azure account user
- the chat and embeddings deployments default to `GlobalStandard` with capacity `30`
- the API is imported with `subscription-required false`, so the APIM endpoint does not require a subscription key
- the chat backend uses APIM system-assigned managed identity to call Azure OpenAI
- the semantic cache policy uses the `openai-backend` and `embeddings-backend` APIM backends
- if the selected model versions are not available in your subscription or region, update `chatModelVersion` and `embeddingsModelVersion` in `setup.ps1`

## How RediSearch Fits

This demo uses Redis Enterprise with the RediSearch module because APIM semantic caching is not just a key-value lookup. APIM first needs a way to compare the meaning of the current prompt with previously seen prompts. RediSearch provides the indexing and vector search capabilities that let Redis store embeddings and find semantically similar requests instead of only exact string matches.

In this repo, APIM uses the `llm-semantic-cache-lookup` policy in the inbound pipeline. That policy calls the `embeddings-backend` to generate an embedding for the incoming chat request, then checks the external Redis cache for a close semantic match. If a matching cached response is found, APIM can return it without forwarding the chat request to the main OpenAI chat backend. If no match is found, APIM forwards the request to `openai-backend`, gets the live model response, and `llm-semantic-cache-store` writes the new prompt/response pair back into Redis for future lookups.

### `llm-semantic-cache-lookup` properties

Microsoft Learn reference: [llm-semantic-cache-lookup policy](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-lookup-policy#attributes) and [elements](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-lookup-policy#elements).

| Property | What it does | Required in docs | Value in this repo | Min / max or allowed values |
| --- | --- | --- | --- | --- |
| [`score-threshold`](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-lookup-policy#attributes) | Sets how close the incoming prompt embedding must be to a cached prompt before APIM returns the cached response. Lower values require a closer semantic match. | Yes | `0.05` | Min `0.0`, max `1.0` |
| [`embeddings-backend-id`](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-lookup-policy#attributes) | Tells APIM which backend to call to generate embeddings for the lookup. | Yes | `embeddings-backend` |  |
| [`embeddings-backend-auth`](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-lookup-policy#attributes) | Sets the authentication mode used for the embeddings backend. The docs require `system-assigned`. | Yes | `system-assigned` | Allowed value: `system-assigned` |
| [`ignore-system-messages`](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-lookup-policy#attributes) | When `true`, APIM removes system messages before comparing prompts for cache similarity. | No | `true` | Allowed values: `true` or `false` |
| [`max-message-count`](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-lookup-policy#attributes) | Skips semantic caching if the conversation contains more messages than this limit. | No | `10` |  |
| [`vary-by`](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-lookup-policy#elements) | Child element that partitions the cache so different callers or scenarios do not all share the same semantic cache entries. Multiple `vary-by` elements can be combined. | No | `shared` |  |

In this repo, those settings mean APIM always uses the `embeddings-backend`, authenticates to it with APIM's system-assigned managed identity, ignores system messages during similarity comparison, and only attempts semantic caching for conversations up to 10 messages. The `vary-by` value is set to `shared`, so all callers use the same cache partition instead of being split by subscription, user, or tenant.

### `llm-semantic-cache-store` properties

Microsoft Learn reference: [llm-semantic-cache-store policy](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-store-policy#attributes).

| Property | What it does | Required in docs | Value in this repo | Min / max or allowed values |
| --- | --- | --- | --- | --- |
| [`duration`](https://learn.microsoft.com/en-us/azure/api-management/llm-semantic-cache-store-policy#attributes) | Sets the cache entry time-to-live in seconds. The docs note that policy expressions are also allowed. | Yes | `300` |  |

For `llm-semantic-cache-store`, the docs only define the `duration` attribute, so there are no additional missing attributes beyond what this repo already uses. Here, `duration="300"` means APIM keeps the cached semantic result for 300 seconds, or 5 minutes, before it expires from the external cache. In other words, after a cache miss and live model call, similar requests that arrive during that 5-minute window can be served from Redis instead of calling the chat model again.

The practical effect is that repeated or very similar prompts can be served from Redis instead of re-running the full chat completion each time. That reduces backend calls, lowers latency for similar requests, and gives you a visible cache hit/miss signal in the APIM telemetry queried by `query-cache-results.ps1`.

## Test

Call the APIM endpoint directly, or use the helper scripts in `scripts`.

Single request:

```powershell
.\scripts\invoke-chat-once.ps1 -suffix "bnrydad" -chatDeployment "chatdemo" -prompt "hi what is your name"
```

Query recent cache results:

```powershell
.\scripts\query-cache-results.ps1 -group "rg-apim-semantic-cache" -chatDeployment "chatdemo" -appInsights "appibnrydad"
```

Once invoked, the sample output will indicate the operation ID and whether the request was a cache Hit or Miss against the semantic cache policy.

```powershell
Time (EDT)          Id               Success Cache Request
----------          --               ------- ----- -------
2026-05-12 14:26:54 df984edd1893575d True    Miss  /openai/deployments/chatdemo/chat/completions?api-version=2024-02-01
2026-05-12 14:27:05 c124700cbfbb8be8 True    Hit   /openai/deployments/chatdemo/chat/completions?api-version=2024-02-01
2026-05-12 14:29:27 d636edffa825b38a True    Hit   /openai/deployments/chatdemo/chat/completions?api-version=2024-02-01
2026-05-12 14:29:33 bd1aed014267bde4 True    Hit   /openai/deployments/chatdemo/chat/completions?api-version=2024-02-01
2026-05-12 14:29:45 084584d989493234 True    Hit   /openai/deployments/chatdemo/chat/completions?api-version=2024-02-01
```

Repeat the same or similar prompts and inspect the `Cache` column in the query output to see semantic cache behavior.