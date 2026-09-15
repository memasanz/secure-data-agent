// =====================================================================================
// Module - Azure DNS Private Resolver (inbound endpoint)
// Lets Point-to-Site VPN clients resolve privatelink.* records, which they cannot
// do against Azure DNS (168.63.129.16) directly. Point the VPN client / VNet DNS
// at this inbound endpoint IP.
// =====================================================================================

@description('Azure region.')
param location string

@description('Name of the DNS Private Resolver.')
param resolverName string = 'dnspr-fabric-foundry'

@description('Resource ID of the VNet the resolver is attached to.')
param vnetId string

@description('Resource ID of the subnet delegated to Microsoft.Network/dnsResolvers.')
param dnsResolverSubnetId string

resource resolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: resolverName
  location: location
  properties: {
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource inboundEndpoint 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: resolver
  name: 'inbound'
  location: location
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Dynamic'
        subnet: {
          id: dnsResolverSubnetId
        }
      }
    ]
  }
}

@description('Private IP of the inbound endpoint. Use this as the VPN client / VNet DNS server.')
output inboundEndpointIp string = inboundEndpoint.properties.ipConfigurations[0].privateIpAddress
output resolverId string = resolver.id
