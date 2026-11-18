targetScope = 'resourceGroup'

param location string = 'eastus2'
@description('East US 2 currently has no capacity for new Search services. Keep retrieval in the US geography.')
param searchLocation string = 'eastus'
param uploadVnetName string = 'regiq-upload-vnet'
param uploadStorageName string = 'regiqvqx35xnseaqaw'

@description('Object ID of the operator deploying and configuring the private pilot.')
param operatorObjectId string

@description('Deploy dependencies first. Enable only after their provisioning roles propagate.')
param deployFoundry bool = false

var suffix = uniqueString(resourceGroup().id, 'native-iq')
// Officers with a per-officer domain come from the officer registry.
var subnetPrefixes = {
  a: '10.82.2.0/24'
  b: '10.82.3.0/24'
}
var officers = [for officer in filter(loadJsonContent('../../config/officers.json').officers, o => contains(o, 'optionA') && o.optionA): {
  key: officer.key
  objectId: officer.objectId
  container: officer.container
  subnetPrefix: subnetPrefixes[officer.key]
}]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: uploadVnetName
}

@batchSize(1)
resource agentSubnets 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = [for officer in officers: {
  parent: vnet
  name: 'native-agent-${officer.key}'
  properties: {
    addressPrefix: officer.subnetPrefix
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
}]

var dnsNames = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
  'privatelink.search.windows.net'
  'privatelink.documents.azure.com'
]

module dns './modules/dns.bicep' = [for name in dnsNames: {
  name: 'native-dns-${uniqueString(deployment().name, name)}'
  params: {
    name: name
    vnetId: vnet.id
  }
}]

resource blobDns 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
}

module domains './modules/domain.bicep' = [for (officer, i) in officers: {
  name: 'native-officer-${officer.key}-${uniqueString(deployment().name)}'
  params: {
    location: location
    searchLocation: searchLocation
    name: 'regiq-${officer.key}-${suffix}'
    storageName: 'riq${officer.key}${suffix}'
    runtimeStorageName: 'rih${officer.key}${suffix}'
    officerObjectId: officer.objectId
    sourceStorageName: uploadStorageName
    sourceContainer: officer.container
    operatorObjectId: operatorObjectId
    deployFoundry: deployFoundry
    agentSubnetId: agentSubnets[i].id
    endpointSubnetId: '${vnet.id}/subnets/private-endpoints'
    blobDnsId: blobDns.id
    foundryDnsIds: [
      dns[0].outputs.id
      dns[1].outputs.id
      dns[2].outputs.id
    ]
    searchDnsId: dns[3].outputs.id
    cosmosDnsId: dns[4].outputs.id
  }
}]

output domains array = [for (officer, i) in officers: domains[i].outputs.configuration]
output consumerAccessEnabled bool = false
