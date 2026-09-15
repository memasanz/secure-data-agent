// Bring-your-own Azure AI Search for Stage 03.
//
// eastus2 (and westus3) were out of Search capacity for standard/basic SKUs, so
// the Search service is created in westus2 and passed to the Foundry sample via
// aiSearchResourceId. The sample then builds the cross-region private endpoint
// (into snet-pe, eastus2) plus the privatelink.search.windows.net DNS zone and
// role assignments. Auth/network settings mirror the sample's own Search so it
// passes the validate-search-aad-auth guard (authType=AAD).

@description('Azure region for the Search service (out-of-capacity workaround; westus2 had capacity).')
param location string = 'westus2'

@description('Name of the AI Search service.')
param aiSearchName string

@description('Search SKU. standard/basic were unavailable in westus3/eastus2; basic in westus2 had capacity and supports AAD + private endpoints + vector search.')
param skuName string = 'basic'

resource aiSearch 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: aiSearchName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    disableLocalAuth: false
    authOptions: { aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' } }
    encryptionWithCmk: {
      enforcement: 'Unspecified'
    }
    hostingMode: 'default'
    partitionCount: 1
    publicNetworkAccess: 'disabled'
    replicaCount: 1
    semanticSearch: 'disabled'
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
  }
  sku: {
    name: skuName
  }
}

output aiSearchResourceId string = aiSearch.id
output aiSearchName string = aiSearch.name
