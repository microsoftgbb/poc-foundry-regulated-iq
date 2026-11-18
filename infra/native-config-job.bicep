targetScope = 'resourceGroup'

param location string = 'eastus2'
param uploadVnetName string = 'regiq-upload-vnet'
param manifests array
param domainNames array
param verifyOnly bool = false
param runSmokeTest bool = false

@description('Optional synthetic end-to-end cases: name, officerObjectId, question, mustContain, mustNotContain.')
param e2eCases array = []

@description('Emit validated Teams app packages for custom-app upload.')
param teamsPackage bool = false

@secure()
@description('Operator ai.azure.com token, only for teamsPackage. Redeploy without it afterwards.')
param operatorToken string = ''

@allowed([
  'private'
  'shared'
])
@description('private = option A per-officer domains; shared = option B shared agent (scripts/configure-native-shared.ps1).')
param script string = 'private'

@description('Option B shared domain: name, officerObjectIds, operatorObjectId.')
param sharedConfig object = {}

@description('Option B steps, comma separated: configure, test, package.')
param sharedSteps string = 'configure'

@secure()
@description('Operator search.azure.com token, only for the option B isolation tests. Redeploy without it afterwards.')
param operatorSearchToken string = ''

var runnerName = 'regiq-config-${uniqueString(resourceGroup().id, 'native-config')}'
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

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: runnerName
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: uploadVnetName
}

resource job 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${runnerName}-job'
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
        name: 'configure'
        properties: {
          image: 'mcr.microsoft.com/azure-powershell@sha256:47d2b89d8299aa73b112c260c32ca7ea23c9960d9149b18029cc3486c8d2dac7'
          command: [
            'pwsh'
            '-NoLogo'
            '-NonInteractive'
            '-Command'
            '${replace(bootstrap, '__CLIENT_ID__', identity.properties.clientId)}\n${script == 'shared' ? loadTextContent('../scripts/configure-native-shared.ps1') : loadTextContent('../scripts/configure-native-private.ps1')}'
          ]
          environmentVariables: [
            {
              name: 'NATIVE_VERIFY_ONLY'
              value: string(verifyOnly)
            }
            {
              name: 'NATIVE_SMOKE_TEST'
              value: string(runSmokeTest)
            }
            {
              name: 'OPERATOR_TOKEN'
              secureValue: operatorToken
            }
            {
              name: 'OPERATOR_SEARCH_TOKEN'
              secureValue: operatorSearchToken
            }
            {
              name: 'SHARED_CONFIG'
              value: string(union(sharedConfig, { officerObjectIds: map(loadJsonContent('officers.json').officers, o => o.objectId) }))
            }
            {
              name: 'SHARED_ANALYZER'
              value: script == 'shared' ? loadTextContent('../native/analyzer.json') : ''
            }
            {
              name: 'SHARED_STEPS'
              value: sharedSteps
            }
            {
              name: 'NATIVE_TEAMS_PACKAGE'
              value: string(teamsPackage)
            }
            {
              name: 'NATIVE_E2E_CASES'
              value: string(e2eCases)
            }
            {
              name: 'DOMAIN_NAMES'
              value: string(domainNames)
            }
            {
              name: 'NATIVE_MANIFEST'
              value: string(manifests)
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
}

output jobName string = job.name
output consumerAccessEnabled bool = false
