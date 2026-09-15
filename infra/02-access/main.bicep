// =====================================================================================
// Stage 02 - Private access layer
// Deploys the inbound access path the upstream Foundry sample does NOT provide:
//   * Point-to-Site VPN Gateway (Entra ID auth) so a dev machine can enter the VNet
//   * Azure DNS Private Resolver so P2S clients can resolve privatelink.* records
//
// Run AFTER stage 01 (network). Reference the VNet created there.
// Scope: resourceGroup
// =====================================================================================

targetScope = 'resourceGroup'

@description('Azure region. Must match stage 01.')
param location string = 'eastus2'

@description('Resource ID of the VNet created in stage 01.')
param vnetId string

@description('Resource ID of the DNS resolver subnet (snet-dnsresolver) from stage 01.')
param dnsResolverSubnetId string

@description('Resource ID of the GatewaySubnet from stage 01.')
param gatewaySubnetId string

@description('P2S VPN client address pool. MUST NOT overlap the VNet address space (192.168.0.0/16).')
param vpnClientAddressPool string = '172.16.0.0/24'

@description('Set false to skip the (slow) VPN gateway deployment, e.g. to deploy just the DNS resolver first.')
param deployVpnGateway bool = true

module dnsResolver 'modules/dns-private-resolver.bicep' = {
  name: 'dns-private-resolver'
  params: {
    location: location
    vnetId: vnetId
    dnsResolverSubnetId: dnsResolverSubnetId
  }
}

module vpn 'modules/vpn-gateway.bicep' = if (deployVpnGateway) {
  name: 'vpn-gateway'
  params: {
    location: location
    gatewaySubnetId: gatewaySubnetId
    vpnClientAddressPool: vpnClientAddressPool
  }
}

@description('Point your VNet custom DNS (and therefore the P2S clients) at this IP after deployment.')
output dnsResolverInboundIp string = dnsResolver.outputs.inboundEndpointIp
