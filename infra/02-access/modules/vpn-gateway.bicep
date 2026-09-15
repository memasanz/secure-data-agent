// =====================================================================================
// Module - Point-to-Site VPN Gateway (Microsoft Entra ID authentication)
// Lets an individual developer machine connect into the VNet to reach the
// private Fabric workspace and Foundry endpoints. No on-prem device required.
//
// NOTE: VPN gateway provisioning is slow (typically 30-45 minutes).
// =====================================================================================

@description('Azure region.')
param location string

@description('Name of the VPN gateway.')
param gatewayName string = 'vpngw-fabric-foundry'

@description('Resource ID of the GatewaySubnet.')
param gatewaySubnetId string

@description('Gateway SKU. Only zone-redundant AZ SKUs are supported for new VPN gateways.')
@allowed([
  'VpnGw1AZ'
  'VpnGw2AZ'
  'VpnGw3AZ'
])
param gatewaySku string = 'VpnGw1AZ'

@description('P2S VPN client address pool. MUST NOT overlap the VNet address space.')
param vpnClientAddressPool string = '172.16.0.0/24'

@description('Entra ID tenant GUID used for VPN authentication.')
param tenantId string = subscription().tenantId

@description('Audience (application ID) for the Azure VPN Client. Default is the Azure Public cloud Azure VPN app ID.')
param aadAudience string = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${gatewayName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = {
  name: gatewayName
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation2'
    sku: {
      name: gatewaySku
      tier: gatewaySku
    }
    activeActive: false
    enableBgp: false
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: gatewaySubnetId
          }
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
    vpnClientConfiguration: {
      vpnClientAddressPool: {
        addressPrefixes: [
          vpnClientAddressPool
        ]
      }
      vpnClientProtocols: [
        'OpenVPN'
      ]
      vpnAuthenticationTypes: [
        'AAD'
      ]
      aadTenant: '${environment().authentication.loginEndpoint}${tenantId}/'
      aadAudience: aadAudience
      aadIssuer: 'https://sts.windows.net/${tenantId}/'
    }
  }
}

output gatewayId string = vpnGateway.id
output gatewayPublicIpId string = pip.id
