targetScope = 'resourceGroup'

// One-shot private job that publishes each officer's agent to Teams using the
// operator's short-lived Foundry token. Delete the container group after it
// finishes; the token is only held as a secure environment value.

param location string = 'eastus2'
param uploadVnetName string = 'regiq-upload-vnet'

@description('Domains: foundryAccount, officerLabel, displayName.')
param domains array

@description('Semantic app version; increment to republish.')
param appVersion string = '1.0.0'

@allowed(['publish', 'package'])
param mode string = 'publish'

param jobName string = 'regiq-publish-teams-job'

@secure()
@description('Operator access token for https://ai.azure.com, from az account get-access-token.')
param operatorToken string

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: uploadVnetName
}

resource job 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: jobName
  location: location
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
        name: 'publish'
        properties: {
          image: 'mcr.microsoft.com/azure-powershell@sha256:47d2b89d8299aa73b112c260c32ca7ea23c9960d9149b18029cc3486c8d2dac7'
          command: [
            'pwsh'
            '-NoLogo'
            '-NonInteractive'
            '-Command'
            loadTextContent('../scripts/publish-native-teams.ps1')
          ]
          environmentVariables: [
            {
              name: 'PUBLISH_DOMAINS'
              value: string(domains)
            }
            {
              name: 'PUBLISH_APP_VERSION'
              value: appVersion
            }
            {
              name: 'PUBLISH_MODE'
              value: mode
            }
            {
              name: 'OPERATOR_TOKEN'
              secureValue: operatorToken
            }
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 1
            }
          }
        }
      }
    ]
  }
}

output jobName string = job.name
