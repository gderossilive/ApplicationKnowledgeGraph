targetScope = 'resourceGroup'

@description('Azure region for all demo resources.')
param location string = resourceGroup().location

@description('Logical environment name used to derive deterministic Azure resource names.')
@minLength(3)
@maxLength(16)
param environmentName string = 'demo'

@description('Administrator account configured on both Windows VMs.')
param adminUsername string

@secure()
@description('Administrator password configured on both Windows VMs.')
param adminPassword string

@description('CIDR allowed to open RDP to the POS VM. Set this to a trusted public IP range before deployment.')
param adminSourceCidr string

@description('Windows VM size for the POS application server.')
param posVmSize string = 'Standard_D2s_v5'

@description('Windows VM size for the private product catalog server.')
param catalogVmSize string = 'Standard_B2s'

@description('Versioned URI of the POS bootstrap script. Host this script in a controlled artifact location before deployment.')
param posBootstrapScriptUri string

@description('Versioned URI of the catalog bootstrap script. Host this script in a controlled artifact location before deployment.')
param catalogBootstrapScriptUri string

@description('Versioned URI of the precompiled POS ZIP artifact.')
param posArtifactUri string

@description('SHA-256 checksum for the precompiled POS ZIP artifact.')
param posArtifactSha256 string

@description('Versioned URI of the isolated POS.mdb database seed.')
param posDatabaseUri string

@description('SHA-256 checksum for the isolated POS.mdb database seed.')
param posDatabaseSha256 string

@description('URI for the supported ASP.NET Core 2.2 Hosting Bundle installer retained by your artifact repository.')
param aspNetCoreHostingBundleUri string

@description('URI for the Microsoft Access Database Engine 2010 x64 installer retained by your artifact repository.')
param accessDatabaseEngineUri string

@description('Versioned URI of the catalog stub ZIP artifact containing CatalogStub.ps1 and catalog.json.')
param catalogArtifactUri string

@description('SHA-256 checksum for the catalog stub ZIP artifact.')
param catalogArtifactSha256 string

var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, location, environmentName))
var virtualNetworkName = 'azvnet${resourceToken}'
var posSubnetName = 'pos'
var catalogSubnetName = 'catalog'
var posVmName = 'azpos${resourceToken}'
var catalogVmName = 'azcat${resourceToken}'
var posComputerName = 'azpos${substring(resourceToken, 0, 10)}'
var catalogComputerName = 'azcat${substring(resourceToken, 0, 10)}'
var posPrivateIp = '10.42.1.4'
var catalogPrivateIp = '10.42.2.4'
var catalogApiPort = 8080
var windowsImage = {
  publisher: 'MicrosoftWindowsServer'
  offer: 'WindowsServer'
  sku: '2022-datacenter-azure-edition'
  version: 'latest'
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/16'
      ]
    }
    subnets: [
      {
        name: posSubnetName
        properties: {
          addressPrefix: '10.42.1.0/24'
        }
      }
      {
        name: catalogSubnetName
        properties: {
          addressPrefix: '10.42.2.0/24'
        }
      }
    ]
  }
}

resource posNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'aznsgpos${resourceToken}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHttpForTemporaryDemo'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowRdpFromAdminNetwork'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: adminSourceCidr
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource catalogNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'aznsgcat${resourceToken}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowCatalogFromPosOnly'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: string(catalogApiPort)
          sourceAddressPrefix: '10.42.1.0/24'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowRdpFromAdminNetwork'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: adminSourceCidr
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource posPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'azpippos${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource posNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'aznicpos${resourceToken}'
  location: location
  properties: {
    networkSecurityGroup: {
      id: posNsg.id
    }
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: posPrivateIp
          publicIPAddress: {
            id: posPublicIp.id
          }
          subnet: {
            id: '${vnet.id}/subnets/${posSubnetName}'
          }
        }
      }
    ]
  }
}

resource catalogNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'azniccat${resourceToken}'
  location: location
  properties: {
    networkSecurityGroup: {
      id: catalogNsg.id
    }
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: catalogPrivateIp
          subnet: {
            id: '${vnet.id}/subnets/${catalogSubnetName}'
          }
        }
      }
    ]
  }
}

resource posVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: posVmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: posVmSize
    }
    osProfile: {
      computerName: posComputerName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: windowsImage
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: posNic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

resource catalogVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: catalogVmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: catalogVmSize
    }
    osProfile: {
      computerName: catalogComputerName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: windowsImage
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: catalogNic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

resource posBootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: posVm
  name: 'azextpos${resourceToken}'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      fileUris: [
        posBootstrapScriptUri
      ]
      commandToExecute: 'powershell.exe -ExecutionPolicy Bypass -File Bootstrap-PosVm.ps1 -PosArtifactUri "${posArtifactUri}" -PosArtifactSha256 "${posArtifactSha256}" -DatabaseUri "${posDatabaseUri}" -DatabaseSha256 "${posDatabaseSha256}" -CatalogBaseUrl "http://${catalogPrivateIp}:${catalogApiPort}/webbff/v1/products/" -AspNetCoreHostingBundleUri "${aspNetCoreHostingBundleUri}" -AccessDatabaseEngineUri "${accessDatabaseEngineUri}"'
    }
  }
}

resource catalogBootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: catalogVm
  name: 'azextcat${resourceToken}'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      fileUris: [
        catalogBootstrapScriptUri
      ]
      commandToExecute: 'powershell.exe -ExecutionPolicy Bypass -File Bootstrap-CatalogVm.ps1 -CatalogArtifactUri "${catalogArtifactUri}" -CatalogArtifactSha256 "${catalogArtifactSha256}"'
    }
  }
}

output posPublicIpAddress string = posPublicIp.properties.ipAddress
output catalogPrivateIpAddress string = catalogPrivateIp
output catalogProductBaseUrl string = 'http://${catalogPrivateIp}:${catalogApiPort}/webbff/v1/products/'