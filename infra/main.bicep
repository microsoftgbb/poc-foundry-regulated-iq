targetScope = 'subscription'

@description('Dedicated resource group for the private upload foundation.')
param resourceGroupName string = 'rg-regiq-caldova-poc'

@description('US Azure region for this commercial synthetic-data PoC.')
@allowed([
  'eastus2'
])
param location string = 'eastus2'

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    workload: 'regiq-private-uploads'
    environment: 'poc'
    dataClassification: 'synthetic'
  }
}

module uploads 'private-uploads.bicep' = {
  name: 'private-uploads'
  scope: group
  params: {
    location: location
  }
}

output resourceGroupId string = group.id
output storageAccountId string = uploads.outputs.storageAccountId
output storageAccountName string = uploads.outputs.storageAccountName
output blobEndpoint string = uploads.outputs.blobEndpoint
output virtualNetworkId string = uploads.outputs.virtualNetworkId
output privateEndpointId string = uploads.outputs.privateEndpointId
output containers array = uploads.outputs.containers
