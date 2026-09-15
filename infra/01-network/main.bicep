// =====================================================================================
// Stage 01 - Network foundation
// Creates the greenfield VNet and the four subnets required by the private
// Fabric + Foundry Agent Service architecture.
//
// IMPORTANT: The Foundry Agent Service injection subnet MUST live in the 172.x or
// 192.x address space (the platform rejects 10.x). The whole VNet therefore uses
// 192.168.0.0/16 to keep things simple and compliant.
//
// Scope: resourceGroup
// =====================================================================================

targetScope = 'resourceGroup'

@description('Azure region for all resources. Must match every other stage.')
param location string = 'eastus2'

@description('Name of the virtual network.')
param vnetName string = 'vnet-fabric-foundry'

@description('VNet address space. Must be in the 172.x or 192.x range for Foundry agent injection.')
param vnetAddressPrefix string = '192.168.0.0/16'

@description('Private endpoints subnet prefix.')
param peSubnetPrefix string = '192.168.0.0/24'

@description('Foundry Agent Service injection subnet prefix (/27 or larger). Delegated to Microsoft.App/environments.')
param agentSubnetPrefix string = '192.168.1.0/27'

@description('Azure DNS Private Resolver inbound subnet prefix (/28 or larger). Delegated to Microsoft.Network/dnsResolvers.')
param dnsResolverSubnetPrefix string = '192.168.1.32/28'

@description('VPN GatewaySubnet prefix (/27 or larger). The name MUST be GatewaySubnet.')
param gatewaySubnetPrefix string = '192.168.2.0/27'

var peSubnetName = 'snet-pe'
var agentSubnetName = 'snet-agents'
var dnsResolverSubnetName = 'snet-dnsresolver'

resource peNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${peSubnetName}'
  location: location
}

resource agentNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${agentSubnetName}'
  location: location
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          networkSecurityGroup: {
            id: peNsg.id
          }
          // Required so private endpoint NICs can be created in this subnet.
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        name: agentSubnetName
        properties: {
          addressPrefix: agentSubnetPrefix
          networkSecurityGroup: {
            id: agentNsg.id
          }
          delegations: [
            {
              name: 'delegation-app-environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: dnsResolverSubnetName
        properties: {
          addressPrefix: dnsResolverSubnetPrefix
          delegations: [
            {
              name: 'delegation-dns-resolvers'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output peSubnetName string = peSubnetName
output peSubnetId string = '${vnet.id}/subnets/${peSubnetName}'
output agentSubnetName string = agentSubnetName
output agentSubnetId string = '${vnet.id}/subnets/${agentSubnetName}'
output dnsResolverSubnetId string = '${vnet.id}/subnets/${dnsResolverSubnetName}'
output gatewaySubnetId string = '${vnet.id}/subnets/GatewaySubnet'
