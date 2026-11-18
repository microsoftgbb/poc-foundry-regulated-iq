param location string
param searchLocation string
param name string
param storageName string
param runtimeStorageName string
param officerObjectId string
param sourceStorageName string
param sourceContainer string
param operatorObjectId string
param deployFoundry bool
param agentSubnetId string
param endpointSubnetId string
param blobDnsId string
param foundryDnsIds array
param searchDnsId string
param cosmosDnsId string

var tags = {
  workload: 'regiq-native-iq'
  environment: 'pilot'
  consumerRelease: 'disabled'
}
var blobContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var searchContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
var searchReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')
var cosmosOperator = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '230815da-be43-4aae-9cb4-875f7bd000aa')
var storageProperties = {
  minimumTlsVersion: 'TLS1_2'
  supportsHttpsTrafficOnly: true
  allowBlobPublicAccess: false
  allowSharedKeyAccess: false
  defaultToOAuthAuthentication: true
  publicNetworkAccess: 'Disabled'
  networkAcls: {
    defaultAction: 'Deny'
    bypass: 'None'
  }
  encryption: {
    keySource: 'Microsoft.Storage'
    requireInfrastructureEncryption: true
    services: {
      blob: {
        enabled: true
      }
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: storageProperties
}

resource runtimeStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = if (deployFoundry) {
  name: runtimeStorageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: storageProperties
}

resource runtimeStorageProvisioner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(runtimeStorage!.id, operatorObjectId, blobContributor)
  scope: runtimeStorage
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: blobContributor
  }
}

module runtimeStorageEndpoint './endpoint.bicep' = if (deployFoundry) {
  name: '${name}-runtime-storage-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-runtime-blob-pe'
    location: location
    subnetId: endpointSubnetId
    targetId: runtimeStorage!.id
    groupId: 'blob'
    dnsZoneIds: [
      blobDnsId
    ]
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

var containerNames = [
  'analysis-pending'
  'approved-content'
  'approval-ledger'
]
resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = [for container in containerNames: {
  parent: blobs
  name: container
  properties: {
    publicAccess: 'None'
  }
}]

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: name
  location: searchLocation
  tags: tags
  sku: {
    name: 'standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'Default'
    publicNetworkAccess: 'disabled'
    disableLocalAuth: true
    semanticSearch: 'standard'
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
  }
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' = {
  name: name
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    networkAclBypass: 'None'
    isVirtualNetworkFilterEnabled: true
  }
}

resource storageProvisioner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, operatorObjectId, blobContributor)
  scope: storage
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: blobContributor
  }
}

resource cosmosProvisioner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cosmos.id, operatorObjectId, cosmosOperator)
  scope: cosmos
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: cosmosOperator
  }
}

resource searchProvisioner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, operatorObjectId, searchContributor)
  scope: search
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: searchContributor
  }
}

resource searchApprovedReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containers[1].id, search.id, 'approved-reader')
  scope: containers[1]
  properties: {
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  }
}

resource approvedPrivateLink 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01' = {
  parent: search
  name: 'approved-content'
  properties: {
    privateLinkResourceId: storage.id
    groupId: 'blob'
    requestMessage: 'Read only independently approved Content Understanding output'
  }
}

module storageEndpoint './endpoint.bicep' = {
  name: '${name}-storage-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-blob-pe'
    location: location
    subnetId: endpointSubnetId
    targetId: storage.id
    groupId: 'blob'
    dnsZoneIds: [
      blobDnsId
    ]
  }
}

module searchEndpoint './endpoint.bicep' = {
  name: '${name}-search-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-search-pe'
    location: location
    subnetId: endpointSubnetId
    targetId: search.id
    groupId: 'searchService'
    dnsZoneIds: [
      searchDnsId
    ]
  }
}

module cosmosEndpoint './endpoint.bicep' = {
  name: '${name}-cosmos-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-cosmos-pe'
    location: location
    subnetId: endpointSubnetId
    targetId: cosmos.id
    groupId: 'Sql'
    dnsZoneIds: [
      cosmosDnsId
    ]
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2026-09-15-preview' = if (deployFoundry) {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: name
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    a365LoggingEnabled: false
    storedCompletionsDisabled: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
        useMicrosoftManagedNetwork: false
      }
    ]
  }
  dependsOn: [
    runtimeStorageProvisioner
    cosmosProvisioner
    runtimeStorageEndpoint
    searchEndpoint
    cosmosEndpoint
  ]
}

module foundryEndpoint './endpoint.bicep' = if (deployFoundry) {
  name: '${name}-foundry-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-foundry-pe'
    location: location
    subnetId: endpointSubnetId
    targetId: foundry!.id
    groupId: 'account'
    dnsZoneIds: foundryDnsIds
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-09-15-preview' = if (deployFoundry) {
  parent: foundry
  name: 'caseiq'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Isolated officer case workspace'
    description: 'Native pilot. Consumer access disabled pending release checks.'
  }
  dependsOn: [
    foundryEndpoint
  ]
}

resource runtimeFiles 'Microsoft.CognitiveServices/accounts/projects/connections@2025-10-01-preview' = if (deployFoundry) {
  parent: project
  name: 'runtime-files'
  properties: {
    authType: 'AAD'
    useWorkspaceManagedIdentity: true
    category: 'AzureStorageAccount'
    target: runtimeStorage!.properties.primaryEndpoints.blob
    isSharedToAll: true
    metadata: {
      ResourceId: runtimeStorage!.id
    }
  }
}

resource runtimeState 'Microsoft.CognitiveServices/accounts/projects/connections@2025-10-01-preview' = if (deployFoundry) {
  parent: project
  name: 'runtime-state'
  properties: {
    authType: 'AAD'
    useWorkspaceManagedIdentity: true
    category: 'CosmosDb'
    target: cosmos.properties.documentEndpoint
    isSharedToAll: true
    metadata: {
      ResourceId: cosmos.id
    }
  }
}

resource runtimeVectors 'Microsoft.CognitiveServices/accounts/projects/connections@2025-10-01-preview' = if (deployFoundry) {
  parent: project
  name: 'runtime-vectors'
  properties: {
    authType: 'AAD'
    useWorkspaceManagedIdentity: true
    category: 'CognitiveSearch'
    target: 'https://${search.name}.search.windows.net'
    isSharedToAll: true
    metadata: {
      ResourceId: search.id
    }
  }
}

resource projectHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-06-01' = if (deployFoundry) {
  parent: project
  name: 'caseiq'
  properties: {
    storageConnections: [
      runtimeFiles.name
    ]
    threadStorageConnections: [
      runtimeState.name
    ]
    vectorStoreConnections: [
      runtimeVectors.name
    ]
  }
  dependsOn: [
    projectReader
    projectBlobAccess
    projectCosmosAccess
    runtimeCosmosOperator
    runtimeStorageOperator
  ]
}

resource projectReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(search.id, '${name}/caseiq', searchReader)
  scope: search
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: searchReader
  }
}

resource projectBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(runtimeStorage!.id, '${name}/caseiq', blobContributor)
  scope: runtimeStorage
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: blobContributor
  }
}

resource projectCosmosAccess 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = if (deployFoundry) {
  parent: cosmos
  name: guid(cosmos.id, '${name}/caseiq', 'cosmos-data')
  properties: {
    principalId: project!.identity.principalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: cosmos.id
  }
}

resource runtimeCosmosOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(cosmos.id, '${name}/caseiq', cosmosOperator)
  scope: cosmos
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cosmosOperator
  }
}

resource runtimeStorageOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(runtimeStorage!.id, '${name}/caseiq', 'storage-operator')
  scope: runtimeStorage
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab')
  }
}

resource runtimeModelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(foundry!.id, '${name}/caseiq', 'model-user')
  scope: foundry
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
  }
}

resource analyzerModelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(foundry!.id, 'cu-model-user')
  scope: foundry
  properties: {
    principalId: foundry!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
  }
}

resource chatModel 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = if (deployFoundry) {
  parent: foundry
  name: 'case-chat'
  sku: {
    name: 'Standard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.1'
      version: '2025-11-13'
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource embeddingModel 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = if (deployFoundry) {
  parent: foundry
  name: 'case-embedding'
  sku: {
    name: 'Standard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-3-small'
      version: '1'
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
  dependsOn: [
    chatModel
  ]
}

resource analyzerDeveloper 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(foundry!.id, operatorObjectId, 'cu-contributor')
  scope: foundry
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '59a2dba3-6303-4fd8-9a2e-8cbb4bdda972')
  }
}

resource projectDeveloper 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(project!.id, operatorObjectId, 'foundry-user')
  scope: project
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
  }
}

output configuration object = {
  officerObjectId: officerObjectId
  sourceStorage: sourceStorageName
  sourceContainer: sourceContainer
  derivedStorage: storage.name
  runtimeStorage: deployFoundry ? runtimeStorage!.name : ''
  cosmosAccount: cosmos.name
  searchService: search.name
  foundryAccount: deployFoundry ? foundry!.name : ''
  projectName: deployFoundry ? project!.name : ''
  sourceEndpoint: 'https://${sourceStorageName}.blob.${environment().suffixes.storage}'
  derivedEndpoint: storage.properties.primaryEndpoints.blob
  searchEndpoint: 'https://${search.name}.search.windows.net'
  consumerAccessEnabled: false
}
