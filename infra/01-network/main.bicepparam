using './main.bicep'

param location = 'eastus2'
param vnetName = 'vnet-fabric-foundry'
param vnetAddressPrefix = '192.168.0.0/16'
param peSubnetPrefix = '192.168.0.0/24'
param agentSubnetPrefix = '192.168.1.0/27'
param dnsResolverSubnetPrefix = '192.168.1.32/28'
param gatewaySubnetPrefix = '192.168.2.0/27'
