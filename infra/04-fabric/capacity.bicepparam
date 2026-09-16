using './capacity.bicep'

// Lowercase alphanumeric, start with a letter, no dashes. 3-63 chars.
param capacityName = 'fabricfoundrycap'

param location = 'eastus2'

// Smallest/cheapest F SKU. Bump as needed (F4, F8, ...).
param skuName = 'F4'

// Capacity admins (Entra UPNs or object IDs). REQUIRED.
// Replace the placeholder with your Entra UPN (e.g. you@contoso.onmicrosoft.com)
// or object ID before deploying. See infra/README.md (Stage 04).
param adminMembers = [
  '<CAPACITY_ADMIN_UPN_OR_OBJECT_ID>'
]
