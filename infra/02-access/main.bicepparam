using './main.bicep'

param location = 'eastus2'

// Fill these from stage 01 outputs (az deployment group show ... --query properties.outputs).
param vnetId = '<STAGE01_vnetId>'
param dnsResolverSubnetId = '<STAGE01_dnsResolverSubnetId>'
param gatewaySubnetId = '<STAGE01_gatewaySubnetId>'

param vpnClientAddressPool = '172.16.0.0/24'
param deployVpnGateway = true
