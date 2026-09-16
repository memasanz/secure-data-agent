// Stage 04 — Microsoft Fabric workspace-level private link (inbound).
//
// Deploys the ARM-able parts of the Fabric workspace-level private-link flow:
//   1. Microsoft.Fabric/privateLinkServicesForFabric   (the Fabric PL resource)
//   2. A private endpoint into snet-pe targeting subresource 'workspace'
//   3. privatelink.fabric.microsoft.com private DNS zone + VNet link + DNS group
//
// NOT deployable here (do these manually — see infra/README.md "Fabric" section):
//   - Tenant setting: "Configure workspace-level inbound network rules"
//   - Re-register the Microsoft.Fabric resource provider (first time in tenant)
//   - The workspace must already exist on a Fabric capacity (F SKU)
//   - Deny public access on the workspace (workspace communication policy)
//   - Fabric -> Foundry managed private endpoint (created + approved in Fabric)

targetScope = 'resourceGroup'

@description('Fabric workspace object ID (GUID) to bind the private link to. From the Fabric portal URL after /groups/.')
param workspaceId string

@description('Microsoft Entra tenant ID that owns the Fabric workspace.')
param tenantId string = subscription().tenantId

@description('Name for the Microsoft.Fabric/privateLinkServicesForFabric resource.')
param fabricPrivateLinkName string = 'fabric-pl-fabric-foundry'

@description('Azure region for the private endpoint (co-located with snet-pe).')
param location string = resourceGroup().location

@description('Resource ID of the VNet that hosts snet-pe (used for the DNS zone link).')
param existingVnetResourceId string

@description('Name of the private-endpoint subnet.')
param peSubnetName string = 'snet-pe'

var vnetName = last(split(existingVnetResourceId, '/'))
var fabricDnsZoneName = 'privatelink.fabric.microsoft.com'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: peSubnetName
}

// 1. The Fabric private-link resource (global).
resource fabricPrivateLink 'Microsoft.Fabric/privateLinkServicesForFabric@2024-06-01' = {
  name: fabricPrivateLinkName
  location: 'global'
  properties: {
    tenantId: tenantId
    workspaceId: workspaceId
  }
}

// 2. Private endpoint into snet-pe, subresource 'workspace'.
resource fabricPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${fabricPrivateLinkName}-private-endpoint'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: '${fabricPrivateLinkName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: fabricPrivateLink.id
          groupIds: [ 'workspace' ]
        }
      }
    ]
  }
}

// 3. Private DNS zone + VNet link + DNS zone group.
resource fabricDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: fabricDnsZoneName
  location: 'global'
}

resource fabricDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: fabricDnsZone
  name: 'fabric-fabric-foundry-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

resource fabricDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: fabricPrivateEndpoint
  name: '${fabricPrivateLinkName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: '${fabricPrivateLinkName}-dns-config'
        properties: { privateDnsZoneId: fabricDnsZone.id }
      }
    ]
  }
  dependsOn: [ fabricDnsLink ]
}

output fabricPrivateLinkId string = fabricPrivateLink.id
output fabricPrivateEndpointId string = fabricPrivateEndpoint.id
output fabricDnsZoneId string = fabricDnsZone.id
