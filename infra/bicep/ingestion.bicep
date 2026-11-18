targetScope = 'resourceGroup'

@description('Region of the private network and ingestion job.')
param location string = 'eastus2'
param uploadVnetName string = 'regiq-upload-vnet'
param sourceStorageName string = 'regiqvqx35xnseaqaw'

@description('Officer domains: officerObjectId, sourceContainer, foundryAccount, searchService, evidenceStorage, analyzerId, analyzerSha256.')
param domains array

@description('Entra object ID of the independent approver who sets the approval Blob index tag.')
param approverObjectId string

@description('Minutes between ingestion reconcile runs.')
@minValue(1)
param intervalMinutes int = 5

@description('Shared-agent pipeline: { searchService, index, foundryAccount, evidenceStorage, analyzerId, analyzerSha256 }. Empty disables it.')
param sharedIndex object = {}

// Single officer registry: every officer's upload container is read by this
// job, and (shared agent) each container binds records to its officer.
var officers = loadJsonContent('../../config/officers.json').officers

var baseName = 'regiq-ingest-${uniqueString(resourceGroup().id, 'native-ingest')}'
var bootstrap = '''
$ErrorActionPreference = 'Stop'
Disable-AzContextAutosave -Scope Process | Out-Null
for ($attempt = 1; ; $attempt++) {
  try {
    Connect-AzAccount -Identity -AccountId '__CLIENT_ID__' -Subscription '6ab9178f-09bc-45be-ba47-f682147eb1f0' -WarningAction SilentlyContinue | Out-Null
    break
  } catch {
    if ($attempt -ge 6) { throw }
    Start-Sleep -Seconds (10 * $attempt)
  }
}
'''
var roles = {
  blobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  contentUnderstandingReader: '379c52cb-64de-498c-8b5b-c6170d6c49d4'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  foundryAgentConsumer: 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6'
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: baseName
  location: location
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: uploadVnetName
}

resource sourceStorage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: sourceStorageName
}

resource sourceBlobs 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' existing = {
  parent: sourceStorage
  name: 'default'
}

resource sourceContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' existing = [for officer in officers: {
  parent: sourceBlobs
  name: officer.container
}]

resource readerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'regiq-case-ingestion-reader')
  properties: {
    roleName: 'RegIQ Case Ingestion Reader'
    description: 'Reads uploaded case Blob versions and their approval tags. Cannot write or approve.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: []
        notActions: []
        dataActions: [
          'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'
          'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read'
        ]
        notDataActions: []
      }
    ]
  }
}

resource approverRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'regiq-case-approver')
  properties: {
    roleName: 'RegIQ Case Approver'
    description: 'Reviews uploaded case PDFs and sets or removes the approval Blob index tag. Cannot upload, change or delete PDFs.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: [
          'Microsoft.Storage/storageAccounts/read'
          'Microsoft.Storage/storageAccounts/blobServices/containers/read'
        ]
        notActions: []
        dataActions: [
          'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'
          'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read'
          'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write'
        ]
        notDataActions: []
      }
    ]
  }
}

resource starterRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'regiq-ingestion-starter')
  properties: {
    roleName: 'RegIQ Ingestion Starter'
    description: 'Reads and starts the private ingestion job. Cannot change its definition or identity.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: [
          'Microsoft.ContainerInstance/containerGroups/read'
          'Microsoft.ContainerInstance/containerGroups/start/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource sourceRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (officer, i) in officers: {
  name: guid(sourceContainers[i].id, identity.id, readerRole.id)
  scope: sourceContainers[i]
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRole.id
  }
}]

resource approverAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sourceStorage.id, approverObjectId, approverRole.id)
  scope: sourceStorage
  properties: {
    principalId: approverObjectId
    principalType: 'User'
    roleDefinitionId: approverRole.id
  }
}

resource evidenceStorage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = [for domain in domains: {
  name: domain.evidenceStorage
}]

resource evidenceWrite 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (domain, i) in domains: {
  name: guid(evidenceStorage[i].id, identity.id, roles.blobDataContributor)
  scope: evidenceStorage[i]
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.blobDataContributor)
  }
}]

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = [for domain in domains: {
  name: domain.foundryAccount
}]

resource analyze 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (domain, i) in domains: {
  name: guid(foundry[i].id, identity.id, roles.contentUnderstandingReader)
  scope: foundry[i]
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.contentUnderstandingReader)
  }
}]

resource projects 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = [for (domain, i) in domains: {
  parent: foundry[i]
  name: 'caseiq'
}]

resource officerConsumer 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (domain, i) in domains: {
  name: guid(projects[i].id, domain.officerObjectId, roles.foundryAgentConsumer)
  scope: projects[i]
  properties: {
    principalId: domain.officerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.foundryAgentConsumer)
  }
}]

resource search 'Microsoft.Search/searchServices@2025-05-01' existing = [for domain in domains: {
  name: domain.searchService
}]

resource runIndexer 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (domain, i) in domains: {
  name: guid(search[i].id, identity.id, roles.searchServiceContributor)
  scope: search[i]
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchServiceContributor)
  }
}]

resource job 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${baseName}-job'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    osType: 'Linux'
    restartPolicy: 'Never'
    subnetIds: [
      {
        id: '${vnet.id}/subnets/native-config'
      }
    ]
    containers: [
      {
        name: 'ingest'
        properties: {
          image: 'mcr.microsoft.com/azure-powershell@sha256:47d2b89d8299aa73b112c260c32ca7ea23c9960d9149b18029cc3486c8d2dac7'
          command: [
            'pwsh'
            '-NoLogo'
            '-NonInteractive'
            '-Command'
            '${replace(bootstrap, '__CLIENT_ID__', identity.properties.clientId)}\n${loadTextContent('../../scripts/ingest.ps1')}'
          ]
          environmentVariables: [
            {
              name: 'INGEST_DOMAINS'
              value: string(domains)
            }
            {
              name: 'INGEST_OFFICERS'
              value: string(map(officers, o => { objectId: o.objectId, container: o.container }))
            }
            {
              name: 'INGEST_SHARED'
              value: empty(sharedIndex) ? '' : string(sharedIndex)
            }
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 2
            }
          }
        }
      }
    ]
  }
  dependsOn: [
    sourceRead
    evidenceWrite
    analyze
    runIndexer
  ]
}

resource scheduler 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${baseName}-schedule'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {
        Reconcile_case_evidence: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Minute'
            interval: intervalMinutes
          }
        }
      }
      actions: {
        Get_ingestion_job: {
          type: 'Http'
          runAfter: {}
          inputs: {
            method: 'GET'
            uri: '${environment().resourceManager}${substring(job.id, 1)}?api-version=2023-05-01'
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: environment().resourceManager
            }
          }
        }
        If_job_is_idle: {
          type: 'If'
          runAfter: {
            Get_ingestion_job: ['Succeeded']
          }
          expression: {
            and: [
              {
                not: {
                  equals: [
                    '@coalesce(body(\'Get_ingestion_job\')?[\'properties\']?[\'instanceView\']?[\'state\'], \'\')'
                    'Running'
                  ]
                }
              }
            ]
          }
          actions: {
            Start_private_ingestion: {
              type: 'Http'
              runAfter: {}
              inputs: {
                method: 'POST'
                uri: '${environment().resourceManager}${substring(job.id, 1)}/start?api-version=2023-05-01'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: environment().resourceManager
                }
              }
            }
            If_start_failed_only_because_job_is_busy: {
              type: 'If'
              runAfter: {
                Start_private_ingestion: ['Failed']
              }
              expression: {
                and: [
                  {
                    equals: [
                      '@outputs(\'Start_private_ingestion\')?[\'statusCode\']'
                      409
                    ]
                  }
                ]
              }
              actions: {}
              else: {
                actions: {
                  Fail_run: {
                    type: 'Terminate'
                    runAfter: {}
                    inputs: {
                      runStatus: 'Failed'
                      runError: {
                        code: 'IngestionStartFailed'
                        message: 'The private ingestion job could not be started.'
                      }
                    }
                  }
                }
              }
            }
          }
          else: {
            actions: {}
          }
        }
      }
    }
  }
}

resource schedulerStart 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(job.id, scheduler.id, starterRole.id)
  scope: job
  properties: {
    principalId: scheduler.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: starterRole.id
  }
}

output jobName string = job.name
output schedulerName string = scheduler.name
output ingestionPrincipalId string = identity.properties.principalId
