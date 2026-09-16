using './capacity.bicep'

// Lowercase alphanumeric, start with a letter, no dashes. 3-63 chars.
param capacityName = 'fabricfoundrycap'

param location = 'eastus2'

// Smallest/cheapest F SKU. Bump as needed (F4, F8, ...).
param skuName = 'F2'

// Capacity admins (Entra UPNs or object IDs). REQUIRED.
param adminMembers = [
  'admin@MngEnvMCAP272547.onmicrosoft.com'
]
