// Stage 04 (optional) — Microsoft Fabric capacity (F SKU).
//
// Workspace-level private link REQUIRES the workspace to sit on a Fabric capacity
// (F SKU). This deploys one. Assign a workspace to it with create-workspace.ps1
// (-CapacityId), or reassign an existing workspace (Workspace settings -> License info).
//
// COST WARNING: F-SKU capacities bill hourly while running (even when idle). Pause
// the capacity when not in use to stop compute billing (Azure portal -> the capacity
// -> Pause, or `az resource invoke-action ... --action pause`). Pausing is a runtime
// action, not a Bicep property.
//
// NAME CONSTRAINTS: 3-63 chars, must match ^[a-z][a-z0-9]*$ (lowercase, start with a
// letter, no dashes/underscores).

targetScope = 'resourceGroup'

@description('Fabric capacity name. Lowercase letters/digits only, must start with a letter (^[a-z][a-z0-9]*$), 3-63 chars.')
@minLength(3)
@maxLength(63)
param capacityName string = 'fabricfoundrycap'

@description('Azure region for the capacity.')
param location string = resourceGroup().location

@description('Fabric capacity SKU (F2, F4, F8, F16, F32, F64, ...). F2 is the smallest/cheapest.')
param skuName string = 'F2'

@description('Capacity administrators (Entra UPNs or object IDs). Required.')
param adminMembers array

resource capacity 'Microsoft.Fabric/capacities@2023-11-01' = {
  name: capacityName
  location: location
  sku: {
    name: skuName
    tier: 'Fabric'
  }
  properties: {
    administration: {
      members: adminMembers
    }
  }
}

output capacityId string = capacity.id
output capacityName string = capacity.name
