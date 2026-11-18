targetScope = 'resourceGroup'

// Option B: one shared private Foundry agent over one shared Foundry IQ index
// whose documents carry native Search ACLs (userIds). Retrieval is trimmed by
// the signed-in officer's own Entra token (UserEntraToken connection), not by
// a per-officer domain. Option A (one domain per officer) is left untouched.

param location string = 'eastus2'
@description('East US 2 has no capacity for new Search services. Keep retrieval in the US geography.')
param searchLocation string = 'eastus'
param uploadVnetName string = 'regiq-upload-vnet'

@description('Object ID of the operator deploying and configuring the pilot.')
param operatorObjectId string

@description('Deploy dependencies first. Enable only after their provisioning roles propagate.')
param deployFoundry bool = false

var suffix = uniqueString(resourceGroup().id, 'native-iq')
var name = 'regiq-s-${suffix}'
var tags = {
  workload: 'regiq-native-iq'
  environment: 'pilot'
  option: 'b-shared-agent'
}
var role = {
  blobContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageOperator: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  searchContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  searchReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  searchDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  cosmosOperator: '230815da-be43-4aae-9cb4-875f7bd000aa'
  foundryUser: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  foundryAgentConsumer: 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6'
  cognitiveServicesUser: 'a97b65f3-24c7-4388-baec-2e87135dc908'
  openAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  contentUnderstandingReader: '379c52cb-64de-498c-8b5b-c6170d6c49d4'
}
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

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: uploadVnetName
}

resource agentSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'native-agent-s'
  properties: {
    addressPrefix: '10.82.5.0/24'
    privateEndpointNetworkPolicies: 'Disabled'
    delegations: [
      {
        name: 'foundry-agent'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
}

resource blobDns 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
}
resource cognitiveDns 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.cognitiveservices.azure.com'
}
resource openAiDns 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.openai.azure.com'
}
resource servicesDns 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.services.ai.azure.com'
}
resource searchDns 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.search.windows.net'
}
resource cosmosDns 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.documents.azure.com'
}

resource configIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: 'regiq-config-${uniqueString(resourceGroup().id, 'native-config')}'
}
resource ingestIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: 'regiq-ingest-${uniqueString(resourceGroup().id, 'native-ingest')}'
}

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: name
  location: searchLocation
  tags: tags
  sku: {
    name: 'basic'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'Default'
    publicNetworkAccess: 'disabled'
    // No API keys: every query must present an Entra token, so native ACL
    // trimming cannot be bypassed with a shared key.
    disableLocalAuth: true
    semanticSearch: 'standard'
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
  }
}

module searchEndpoint './native/endpoint.bicep' = {
  name: '${name}-search-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-search-pe'
    location: location
    subnetId: '${vnet.id}/subnets/private-endpoints'
    targetId: search.id
    groupId: 'searchService'
    dnsZoneIds: [
      searchDns.id
    ]
  }
}

resource runtimeStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: 'rihs${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: storageProperties
}

module runtimeStorageEndpoint './native/endpoint.bicep' = {
  name: '${name}-runtime-storage-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-runtime-blob-pe'
    location: location
    subnetId: '${vnet.id}/subnets/private-endpoints'
    targetId: runtimeStorage.id
    groupId: 'blob'
    dnsZoneIds: [
      blobDns.id
    ]
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

module cosmosEndpoint './native/endpoint.bicep' = {
  name: '${name}-cosmos-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-cosmos-pe'
    location: location
    subnetId: '${vnet.id}/subnets/private-endpoints'
    targetId: cosmos.id
    groupId: 'Sql'
    dnsZoneIds: [
      cosmosDns.id
    ]
  }
}

resource runtimeStorageProvisioner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(runtimeStorage.id, operatorObjectId, role.blobContributor)
  scope: runtimeStorage
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.blobContributor)
  }
}

resource cosmosProvisioner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cosmos.id, operatorObjectId, role.cosmosOperator)
  scope: cosmos
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.cosmosOperator)
  }
}

resource searchProvisioner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, operatorObjectId, role.searchContributor)
  scope: search
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.searchContributor)
  }
}

// Operator query rights for the canary tests. Officers get theirs through
// the officer group (infra/officers.bicep). Which documents anyone sees is
// decided by the index ACLs evaluated against that user's own token.
resource operatorSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, operatorObjectId, role.searchReader)
  scope: search
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.searchReader)
  }
}

resource ingestWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, ingestIdentity.id, role.searchDataContributor)
  scope: search
  properties: {
    principalId: ingestIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.searchDataContributor)
  }
}

// The config identity's Search Service Contributor role comes from
// native/config-roles.bicep (configRoles module below).

// Needed only for the isolation tests: a synthetic canary document and
// negative queries from a service principal without a user token.
resource configSearchData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, configIdentity.id, role.searchDataContributor)
  scope: search
  properties: {
    principalId: configIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.searchDataContributor)
  }
}

// Shared ingestion evidence store: Content Understanding results, approval
// ledger and the record IDs pushed to the shared index, per officer prefix.
resource evidenceStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: 'riqs${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: storageProperties
}

resource evidenceBlobs 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: evidenceStorage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource evidenceContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = [for container in [
  'analysis-pending'
  'approval-ledger'
  'approved-content'
]: {
  parent: evidenceBlobs
  name: container
  properties: {
    publicAccess: 'None'
  }
}]

module evidenceEndpoint './native/endpoint.bicep' = {
  name: '${name}-evidence-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-evidence-blob-pe'
    location: location
    subnetId: '${vnet.id}/subnets/private-endpoints'
    targetId: evidenceStorage.id
    groupId: 'blob'
    dnsZoneIds: [
      blobDns.id
    ]
  }
}

resource ingestEvidence 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(evidenceStorage.id, ingestIdentity.id, role.blobContributor)
  scope: evidenceStorage
  properties: {
    principalId: ingestIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.blobContributor)
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
        subnetArmId: agentSubnet.id
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

module foundryEndpoint './native/endpoint.bicep' = if (deployFoundry) {
  name: '${name}-foundry-${uniqueString(deployment().name)}'
  params: {
    name: '${name}-foundry-pe'
    location: location
    subnetId: '${vnet.id}/subnets/private-endpoints'
    targetId: foundry!.id
    groupId: 'account'
    dnsZoneIds: [
      cognitiveDns.id
      openAiDns.id
      servicesDns.id
    ]
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
    displayName: 'Shared officer case workspace (option B)'
    description: 'One agent for all officers; retrieval trimmed by each officer token.'
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
    target: runtimeStorage.properties.primaryEndpoints.blob
    isSharedToAll: true
    metadata: {
      ResourceId: runtimeStorage.id
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
    projectSearchReader
    projectBlobAccess
    projectCosmosAccess
    projectCosmosOperator
    projectStorageOperator
  ]
}

// The project identity can call Search (the runtime vector store), but the
// case index is ACL protected: without a user token it returns no documents.
resource projectSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(search.id, '${name}/caseiq', role.searchReader)
  scope: search
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.searchReader)
  }
}

resource projectBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(runtimeStorage.id, '${name}/caseiq', role.blobContributor)
  scope: runtimeStorage
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.blobContributor)
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

resource projectCosmosOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(cosmos.id, '${name}/caseiq', role.cosmosOperator)
  scope: cosmos
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.cosmosOperator)
  }
}

resource projectStorageOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(runtimeStorage.id, '${name}/caseiq', 'storage-operator')
  scope: runtimeStorage
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.storageOperator)
  }
}

resource projectModelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(foundry!.id, '${name}/caseiq', 'model-user')
  scope: foundry
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.openAiUser)
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

// Content Understanding runs the custom analyzer with the account identity.
resource analyzerModelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(foundry!.id, 'cu-model-user')
  scope: foundry
  properties: {
    principalId: foundry!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.openAiUser)
  }
}

resource ingestAnalyze 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(foundry!.id, ingestIdentity.id, role.contentUnderstandingReader)
  scope: foundry
  properties: {
    principalId: ingestIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.contentUnderstandingReader)
  }
}

resource operatorProjectUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFoundry) {
  name: guid(project!.id, operatorObjectId, 'foundry-user')
  scope: project
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.foundryUser)
  }
}

module configRoles './native/config-roles.bicep' = if (deployFoundry) {
  name: '${name}-config-roles-${uniqueString(deployment().name)}'
  params: {
    domainName: name
    principalId: configIdentity.properties.principalId
  }
  dependsOn: [
    project
  ]
}

output configuration object = {
  name: name
  searchService: search.name
  searchEndpoint: 'https://${search.name}.search.windows.net'
  foundryAccount: deployFoundry ? foundry!.name : ''
  projectName: deployFoundry ? project!.name : ''
  projectEndpoint: deployFoundry ? 'https://${name}.services.ai.azure.com/api/projects/caseiq' : ''
  evidenceStorage: evidenceStorage.name
}
