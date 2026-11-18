targetScope = 'resourceGroup'

// Network and identity for the private configuration job
// (infra/native-config-job.bicep): an outbound-only NAT, the delegated
// native-config subnet and the scoped configuration managed identity.

param location string = 'eastus2'
param uploadVnetName string = 'regiq-upload-vnet'
param domainNames array

var suffix = uniqueString(resourceGroup().id, 'native-config')
var name = 'regiq-config-${suffix}'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: uploadVnetName
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${name}-egress'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: name
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: publicIp.id
      }
    ]
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'native-config'
  properties: {
    addressPrefix: '10.82.4.0/24'
    natGateway: {
      id: nat.id
    }
    delegations: [
      {
        // Name kept as deployed; the delegation serves the ACI configuration job.
        name: 'deployment-script'
        properties: {
          serviceName: 'Microsoft.ContainerInstance/containerGroups'
        }
      }
    ]
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
}

module roles './modules/config-roles.bicep' = [for domainName in domainNames: {
  name: '${domainName}-config-roles'
  params: {
    domainName: domainName
    principalId: identity.properties.principalId
  }
}]

output identityName string = identity.name
