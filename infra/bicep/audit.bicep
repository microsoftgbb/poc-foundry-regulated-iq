targetScope = 'resourceGroup'

// Metadata-only audit: who accessed which case Blob, Search operations,
// Foundry audit events and ingestion scheduler runs. No document text,
// prompts or answers are sent: RequestResponse/Trace categories are excluded.

param workspaceName string = 'regiq-audit-logs'
param sourceStorageName string = 'regiqvqx35xnseaqaw'
param schedulerName string

@description('Officer domains: foundryAccount, searchService, evidenceStorage.')
param domains array

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

var storageLogs = [
  { category: 'StorageRead', enabled: true }
  { category: 'StorageWrite', enabled: true }
  { category: 'StorageDelete', enabled: true }
]

resource sourceBlobs 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' existing = {
  name: '${sourceStorageName}/default'
}

resource sourceAudit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'regiq-audit'
  scope: sourceBlobs
  properties: {
    workspaceId: workspace.id
    logs: storageLogs
  }
}

resource evidenceBlobs 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' existing = [for domain in domains: {
  name: '${domain.evidenceStorage}/default'
}]

resource evidenceAudit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (domain, i) in domains: {
  name: 'regiq-audit'
  scope: evidenceBlobs[i]
  properties: {
    workspaceId: workspace.id
    logs: storageLogs
  }
}]

resource search 'Microsoft.Search/searchServices@2025-05-01' existing = [for domain in domains: {
  name: domain.searchService
}]

resource searchAudit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (domain, i) in domains: {
  name: 'regiq-audit'
  scope: search[i]
  properties: {
    workspaceId: workspace.id
    logs: [
      { category: 'OperationLogs', enabled: true }
    ]
  }
}]

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = [for domain in domains: {
  name: domain.foundryAccount
}]

resource foundryAudit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (domain, i) in domains: {
  name: 'regiq-audit'
  scope: foundry[i]
  properties: {
    workspaceId: workspace.id
    logs: [
      { category: 'Audit', enabled: true }
    ]
  }
}]

resource scheduler 'Microsoft.Logic/workflows@2019-05-01' existing = {
  name: schedulerName
}

resource schedulerAudit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'regiq-audit'
  scope: scheduler
  properties: {
    workspaceId: workspace.id
    logs: [
      { category: 'WorkflowRuntime', enabled: true }
    ]
  }
}
