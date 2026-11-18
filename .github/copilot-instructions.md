# Copilot instructions

## PoC guardrails

- **Synthetic data only.** Never add real filings, people or tax IDs, and never commit a `*.pdf`.
- **No keys.** Use managed identities and Microsoft Entra ID only. Keep `disableLocalAuth: true` and `allowSharedKeyAccess: false`, and never call `listKeys`.
- **Public access disabled.** Foundry, Search, Content Understanding, Cosmos DB and the evidence and runtime stores keep `publicNetworkAccess: 'Disabled'`. The documented exceptions are Foundry's Microsoft 365 Activity route, and the upload storage account for Azure Portal uploads with Entra authorization.
- **Private execution.** Data-plane scripts run in the ACI jobs inside the VNet and refuse endpoints that don't resolve to private addresses.
- **Approval before exposure.** Only approved, exact Blob versions are published. Knowledge sources keep `approved eq true`.
- **Document-level security.** Shared-index records get `userIds` from the officer-to-container binding in `config/officers.json`, never from document content or model output. Keep `permissionFilterOption: 'enabled'` and the `UserEntraToken` connection.
- **One tool.** Agents allow only `knowledge_base_retrieve`.
- **Tokens.** Operator tokens are secure parameters. Redeploy the configuration job without them afterwards, and never print or log them.
- **Regional models.** Model deployments use regional `Standard` SKUs.
- **Incremental mode only.** Never deploy with `--mode Complete`.
