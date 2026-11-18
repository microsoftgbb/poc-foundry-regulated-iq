targetScope = 'resourceGroup'

param location string = 'eastus2'
param uploadVnetName string = 'regiq-upload-vnet'
param manifests array
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

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: 'riqc${suffix}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource fileRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, 'file-privileged')
  scope: storage
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69566ab7-960f-475b-8e7c-b3118f30c6bd')
  }
}

module dns './native/dns.bicep' = {
  name: 'native-config-file-dns'
  params: {
    name: 'privatelink.file.${environment().suffixes.storage}'
    vnetId: vnet.id
  }
}

module endpoint './native/endpoint.bicep' = {
  name: 'native-config-file-pe'
  params: {
    name: '${name}-file-pe'
    location: location
    subnetId: '${vnet.id}/subnets/private-endpoints'
    targetId: storage.id
    groupId: 'file'
    dnsZoneIds: [
      dns.outputs.id
    ]
  }
}

module roles './native/config-roles.bicep' = [for domainName in domainNames: {
  name: '${domainName}-config-roles'
  params: {
    domainName: domainName
    principalId: identity.properties.principalId
  }
}]

resource script 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: name
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    azPowerShellVersion: '16.2'
    timeout: 'PT30M'
    retentionInterval: 'P1D'
    cleanupPreference: 'Always'
    forceUpdateTag: uniqueString(string(manifests))
    storageAccountSettings: {
      storageAccountName: storage.name
    }
    containerSettings: {
      subnetIds: [
        {
          id: subnet.id
        }
      ]
    }
    environmentVariables: [
      {
        name: 'DOMAIN_NAMES'
        value: string(domainNames)
      }
      {
        name: 'NATIVE_MANIFEST'
        value: string(manifests)
      }
    ]
    scriptContent: loadTextContent('../scripts/configure-native-private.ps1')
  }
  dependsOn: [
    fileRole
    endpoint
    roles
  ]
}

output scriptName string = script.name
output consumerAccessEnabled bool = false
