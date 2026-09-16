using './main.bicep'

// Fabric workspace object ID (GUID). REQUIRED — fill from the Fabric portal URL
// after /groups/. Deployment will fail with the placeholder below.
param workspaceId = '<FABRIC_WORKSPACE_ID>'

// Entra tenant ID (defaults to the subscription tenant if omitted).
param tenantId = '7b3b2559-0c78-44e7-8c57-8455603aca36'

// Stage 01 VNet that hosts snet-pe.
param existingVnetResourceId = '/subscriptions/7ee2b43a-eaea-4259-be7b-c8c220bfbcf9/resourceGroups/rg-fabric-foundry-eus2/providers/Microsoft.Network/virtualNetworks/vnet-fabric-foundry'

param peSubnetName = 'snet-pe'
