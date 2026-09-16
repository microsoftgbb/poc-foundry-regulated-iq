param botName string
param displayName string

@description('Agent identity client_id from instance_identity.client_id')
param msaAppId string

@description('Microsoft Entra tenant ID')
param tenantId string

@description('Agent activity protocol endpoint URL')
param endpoint string

param botServiceSku string = 'F0'

resource botService 'Microsoft.BotService/botServices@2022-09-15' = {
  name: botName
  kind: 'azurebot'
  location: 'global'
  sku: {
    name: botServiceSku
  }
  properties: {
    displayName: displayName
    endpoint: endpoint
    msaAppId: msaAppId
    msaAppTenantId: tenantId
    msaAppType: 'SingleTenant'
    publicNetworkAccess: 'Disabled'
  }
}

resource botServiceMsTeamsChannel 'Microsoft.BotService/botServices/channels@2021-03-01' = {
  parent: botService
  location: 'global'
  name: 'MsTeamsChannel'
  properties: {
    channelName: 'MsTeamsChannel'
  }
}

output botServiceArmId string = botService.id
