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

@secure()
@description('SQL Server sa password used only by the database VM bootstrap.')
param sqlAdminPassword string

@secure()
@description('Least-privileged SQL login password used by the POS application.')
param sqlAppPassword string

@description('CIDR allowed to open RDP to the POS VM. Set this to a trusted public IP range before deployment.')
param adminSourceCidr string

@description('Windows VM size for the POS application server.')
param posVmSize string = 'Standard_D2s_v5'

@description('Windows VM size for the private product catalog server.')
param catalogVmSize string = 'Standard_B2s'

@description('Windows VM size for the private SQL Server Express database server.')
param sqlVmSize string = 'Standard_B2s'

@description('Versioned URI of the POS bootstrap script. Host this script in a controlled artifact location before deployment.')
param posBootstrapScriptUri string

@description('Versioned URI of the catalog bootstrap script. Host this script in a controlled artifact location before deployment.')
param catalogBootstrapScriptUri string

@description('Versioned URI of the SQL Server bootstrap script.')
param sqlBootstrapScriptUri string

@description('Immutable source ZIP used by the POS VM to build the deployment artifact locally.')
param posSourceArchiveUri string

@description('SHA-256 checksum for the POS source ZIP.')
param posSourceArchiveSha256 string

@description('URI for the .NET SDK 2.2.207 Windows installer used to build the legacy POS locally.')
param posBuildSdkUri string

@description('SHA-512 checksum for the .NET SDK 2.2.207 Windows installer.')
param posBuildSdkSha512 string

@description('URI for the supported ASP.NET Core 2.2 Hosting Bundle installer retained by your artifact repository.')
param aspNetCoreHostingBundleUri string

@description('Official URI for the SQL Server 2017 Express x64 bootstrapper downloaded by the SQL VM.')
param sqlServerBootstrapperUri string

@description('SHA-256 checksum for the SQL Server 2017 Express bootstrapper.')
param sqlServerBootstrapperSha256 string

@description('Versioned URI of the Tailwind POS SQL Server schema script.')
param sqlDatabaseSchemaScriptUri string

@description('SHA-256 checksum for the Tailwind POS SQL Server schema script.')
param sqlDatabaseSchemaScriptSha256 string

@description('Versioned URI of the Tailwind POS SQL Server seed script exported from POS.mdb.')
param sqlDatabaseSeedScriptUri string

@description('SHA-256 checksum for the Tailwind POS SQL Server seed script.')
param sqlDatabaseSeedScriptSha256 string

@description('Versioned URI of the catalog stub ZIP artifact containing CatalogStub.ps1 and catalog.json.')
param catalogArtifactUri string

@description('SHA-256 checksum for the catalog stub ZIP artifact.')
param catalogArtifactSha256 string

var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, location, environmentName))
var virtualNetworkName = 'azvnet${resourceToken}'
var posSubnetName = 'pos'
var catalogSubnetName = 'catalog'
var sqlSubnetName = 'sql'
var posVmName = 'azpos${resourceToken}'
var catalogVmName = 'azcat${resourceToken}'
var sqlVmName = 'azsql${resourceToken}'
var posComputerName = 'azpos${substring(resourceToken, 0, 10)}'
var catalogComputerName = 'azcat${substring(resourceToken, 0, 10)}'
var sqlComputerName = 'azsql${substring(resourceToken, 0, 10)}'
var posPrivateIp = '10.42.1.4'
var catalogPrivateIp = '10.42.2.4'
var sqlPrivateIp = '10.42.3.4'
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
      {
        name: sqlSubnetName
        properties: {
          addressPrefix: '10.42.3.0/24'
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

resource sqlNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'aznsgsql${resourceToken}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSqlFromPosOnly'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
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

resource sqlNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'aznicsql${resourceToken}'
  location: location
  properties: {
    networkSecurityGroup: {
      id: sqlNsg.id
    }
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: sqlPrivateIp
          subnet: {
            id: '${vnet.id}/subnets/${sqlSubnetName}'
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

resource sqlVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: sqlVmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: sqlVmSize
    }
    osProfile: {
      computerName: sqlComputerName
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
          id: sqlNic.id
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
      commandToExecute: 'powershell.exe -ExecutionPolicy Bypass -File Bootstrap-PosVm.ps1 -PosSourceArchiveUri "${posSourceArchiveUri}" -PosSourceArchiveSha256 "${posSourceArchiveSha256}" -PosBuildSdkUri "${posBuildSdkUri}" -PosBuildSdkSha512 "${posBuildSdkSha512}" -CatalogBaseUrl "http://${catalogPrivateIp}:${catalogApiPort}/webbff/v1/products/" -AspNetCoreHostingBundleUri "${aspNetCoreHostingBundleUri}" -SqlServerHost "${sqlPrivateIp}" -SqlDatabaseName "TailwindPOS" -SqlAppUsername "tailwindpos_app" -SqlAppPasswordBase64 "${base64(sqlAppPassword)}"'
    }
  }
  dependsOn: [
    sqlBootstrap
  ]
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

resource sqlBootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: sqlVm
  name: 'azextsql${resourceToken}'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      fileUris: [
        sqlBootstrapScriptUri
        sqlDatabaseSchemaScriptUri
        sqlDatabaseSeedScriptUri
      ]
      commandToExecute: 'powershell.exe -ExecutionPolicy Bypass -File Bootstrap-SqlVm.ps1 -SqlServerBootstrapperUri "${sqlServerBootstrapperUri}" -SqlServerBootstrapperSha256 "${sqlServerBootstrapperSha256}" -SqlAdminPasswordBase64 "${base64(sqlAdminPassword)}" -SqlAppPasswordBase64 "${base64(sqlAppPassword)}" -SchemaScriptSha256 "${sqlDatabaseSchemaScriptSha256}" -SeedScriptSha256 "${sqlDatabaseSeedScriptSha256}"'
    }
  }
}

output posPublicIpAddress string = posPublicIp.properties.ipAddress
output catalogPrivateIpAddress string = catalogPrivateIp
output catalogProductBaseUrl string = 'http://${catalogPrivateIp}:${catalogApiPort}/webbff/v1/products/'
output sqlPrivateIpAddress string = sqlPrivateIp