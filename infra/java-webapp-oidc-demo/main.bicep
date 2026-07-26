targetScope = 'resourceGroup'

@description('Azure region for all demo resources.')
param location string = resourceGroup().location

@description('Logical environment name used to derive deterministic Azure resource names.')
@minLength(3)
@maxLength(16)
param environmentName string = 'demo'

@description('Administrator account configured on the Linux VM.')
param adminUsername string

@secure()
@description('Administrator password configured on the Linux VM.')
param adminPassword string

@description('CIDR allowed to open SSH to the VM.')
param adminSourceCidr string

@description('Burstable Linux VM size. B2s provides 4 GiB RAM for Tomcat, Maven and PostgreSQL.')
param vmSize string = 'Standard_B2s'

@description('Versioned URI of the Linux VM bootstrap script.')
param bootstrapScriptUri string

@description('Immutable ZIP containing the Java OIDC source tree.')
param javaSourceArchiveUri string

@description('SHA-256 checksum for the Java OIDC source archive.')
param javaSourceArchiveSha256 string

@description('Versioned URI of the patch that adapts the Java source archive to PostgreSQL.')
param postgresqlPatchUri string

@description('SHA-256 checksum for the PostgreSQL source patch.')
param postgresqlPatchSha256 string

@description('Immutable Java 8 JDK archive used by the legacy application.')
param jdkArchiveUri string

@description('SHA-256 checksum for the Java 8 JDK archive.')
param jdkArchiveSha256 string

@description('Immutable Tomcat 8.5 archive used to host the WAR.')
param tomcatArchiveUri string

@description('SHA-256 checksum for the Tomcat archive.')
param tomcatArchiveSha256 string

@description('Immutable Apache Maven archive used to build the WAR.')
param mavenArchiveUri string

@description('SHA-256 checksum for the Maven archive.')
param mavenArchiveSha256 string

@description('Microsoft Entra tenant domain or tenant ID used by the application.')
param tenantName string

@description('Microsoft Entra application (client) ID.')
param clientId string

@secure()
@description('Microsoft Entra application client secret.')
param clientSecret string

@secure()
@description('Password for the local PostgreSQL application login.')
param postgresqlAppPassword string

var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, location, environmentName))
var virtualNetworkName = 'azvnet${resourceToken}'
var vmSubnetName = 'app'
var vmName = 'azoidc${resourceToken}'
var vmComputerName = 'azoidc${substring(resourceToken, 0, 10)}'
var publicIpName = 'azpipoidc${resourceToken}'
var networkInterfaceName = 'aznicoidc${resourceToken}'
var networkSecurityGroupName = 'aznsgoidc${resourceToken}'
var linuxImage = {
  publisher: 'Canonical'
  offer: '0001-com-ubuntu-server-jammy'
  sku: '22_04-lts-gen2'
  version: 'latest'
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHttpForDemo'
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
        name: 'AllowSshFromAdminNetwork'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: adminSourceCidr
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.43.0.0/16'
      ]
    }
    subnets: [
      {
        name: vmSubnetName
        properties: {
          addressPrefix: '10.43.1.0/24'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: '${virtualNetwork.id}/subnets/${vmSubnetName}'
          }
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmComputerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    storageProfile: {
      imageReference: linuxImage
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
          id: networkInterface.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

resource bootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: virtualMachine
  name: 'azextoidc${resourceToken}'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      fileUris: [
        bootstrapScriptUri
        postgresqlPatchUri
      ]
      commandToExecute: 'bash Bootstrap-JavaOidcVm.sh --source-uri "${javaSourceArchiveUri}" --source-sha256 "${javaSourceArchiveSha256}" --postgres-patch-sha256 "${postgresqlPatchSha256}" --jdk-uri "${jdkArchiveUri}" --jdk-sha256 "${jdkArchiveSha256}" --tomcat-uri "${tomcatArchiveUri}" --tomcat-sha256 "${tomcatArchiveSha256}" --maven-uri "${mavenArchiveUri}" --maven-sha256 "${mavenArchiveSha256}" --tenant "${tenantName}" --client-id "${clientId}" --client-secret-base64 "${base64(clientSecret)}" --postgres-password-base64 "${base64(postgresqlAppPassword)}"'
    }
  }
}

output vmPublicIpAddress string = publicIp.properties.ipAddress
output applicationUrl string = 'http://${publicIp.properties.ipAddress}/'
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'