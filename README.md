# APIM Semantic Cache Demo

This repo contains a simple PowerShell deployment script that uses Azure CLI to create:

- an API Management instance
- an Azure OpenAI in Foundry resource with one chat deployment and one embeddings deployment
- a Redis Enterprise cluster with RediSearch enabled
- an APIM API and policy that uses Redis as a semantic cache for chat completions

## Files

- `scripts/deploy-demo.ps1` deploys and wires the demo
- `apim/openai-chat-api.json` is the minimal OpenAPI document imported into APIM
- `apim/semantic-cache-policy.xml` is the APIM policy that enables semantic cache lookup and store

## Run

```powershell
pwsh ./scripts/deploy-demo.ps1 -suffix demo01 -publisherEmail you@contoso.com -publisherName Contoso
```

## Notes

- use a unique `-suffix` because the APIM and Foundry names must be unique
- the default resource group is `rg-apim-semantic-cache`
- the default location is `eastus2`
- if the selected model versions are not available in your subscription or region, update `chatModelVersion` and `embeddingsModelVersion` in `scripts/deploy-demo.ps1`
- the script ignores create conflicts that only indicate a resource already exists so you can rerun it without adding pre-check scripts

## Test

After deployment, call the APIM endpoint shown by the script output. Repeat the same prompt, then a similar prompt, and inspect APIM tracing to see semantic cache hits.