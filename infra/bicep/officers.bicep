targetScope = 'resourceGroup'

// Officer access, driven by config/officers.json (the single officer registry).
//   per officer : own upload container + Storage Blob Data Contributor on it
//   officer group: Reader on the upload account (Portal browsing),
//                  Foundry Agent Consumer on the shared agent project and
//                  Search Index Data Reader on the shared Search service.
// Which case records an officer can retrieve is not granted here: the shared
// index ACL (userIds) is stamped by ingestion from the container binding.

@description('Object ID of the Entra security group listed in officers.json (scripts/sync-officer-group.ps1 creates it and prints the ID).')
param officerGroupObjectId string

param sourceStorageName string = 'regiqvqx35xnseaqaw'

var registry = loadJsonContent('../../config/officers.json')
var officers = registry.officers
var sharedName = 'regiq-s-${uniqueString(resourceGroup().id, 'native-iq')}'
var role = {
  blobContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  searchReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  foundryAgentConsumer: 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6'
}

resource sourceStorage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: sourceStorageName
}

resource sourceBlobs 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' existing = {
  parent: sourceStorage
  name: 'default'
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = [for officer in officers: {
  parent: sourceBlobs
  name: officer.container
  properties: {
    publicAccess: 'None'
  }
}]

resource uploadRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (officer, i) in officers: {
  name: guid(containers[i].id, officer.objectId, role.blobContributor)
  scope: containers[i]
  properties: {
    principalId: officer.objectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.blobContributor)
  }
}]

resource groupStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sourceStorage.id, officerGroupObjectId, role.reader)
  scope: sourceStorage
  properties: {
    principalId: officerGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.reader)
  }
}

resource sharedFoundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: sharedName
}

resource sharedProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: sharedFoundry
  name: 'caseiq'
}

resource sharedSearch 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: sharedName
}

resource groupAgentConsumer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sharedProject.id, officerGroupObjectId, role.foundryAgentConsumer)
  scope: sharedProject
  properties: {
    principalId: officerGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.foundryAgentConsumer)
  }
}

resource groupSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sharedSearch.id, officerGroupObjectId, role.searchReader)
  scope: sharedSearch
  properties: {
    principalId: officerGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.searchReader)
  }
}

output officers array = [for officer in officers: {
  displayName: officer.displayName
  objectId: officer.objectId
  container: officer.container
}]
