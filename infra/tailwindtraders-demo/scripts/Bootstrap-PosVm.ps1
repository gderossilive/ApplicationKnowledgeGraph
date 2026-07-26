[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$PosArtifactUri,
    [Parameter(Mandatory = $true)] [string]$PosArtifactSha256,
    [Parameter(Mandatory = $true)] [string]$DatabaseUri,
    [Parameter(Mandatory = $true)] [string]$DatabaseSha256,
    [Parameter(Mandatory = $true)] [string]$CatalogBaseUrl,
    [Parameter(Mandatory = $true)] [string]$AspNetCoreHostingBundleUri,
    [Parameter(Mandatory = $true)] [string]$AccessDatabaseEngineUri
)

$ErrorActionPreference = 'Stop'
$appRoot = 'C:\inetpub\TailwindPOS'
$packageRoot = 'C:\TailwindDemo\packages'
$appPoolName = 'TailwindPOS'

function Get-VerifiedFile {
    param([string]$Uri, [string]$Path, [string]$ExpectedSha256)

    Invoke-WebRequest -Uri $Uri -OutFile $Path
    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualSha256 -ne $ExpectedSha256.ToUpperInvariant()) {
        throw "Checksum validation failed for '$Uri'."
    }
}

New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
Install-WindowsFeature -Name Web-Server, Web-Asp-Net45 -IncludeManagementTools | Out-Null

$hostingBundle = Join-Path $packageRoot 'dotnet-hosting.exe'
$accessEngine = Join-Path $packageRoot 'AccessDatabaseEngine_X64.exe'
$posPackage = Join-Path $packageRoot 'TailwindPOS.zip'
$databasePath = Join-Path $appRoot 'POS.mdb'

Invoke-WebRequest -Uri $AspNetCoreHostingBundleUri -OutFile $hostingBundle
Start-Process -FilePath $hostingBundle -ArgumentList '/quiet', '/norestart' -Wait
Invoke-WebRequest -Uri $AccessDatabaseEngineUri -OutFile $accessEngine
Start-Process -FilePath $accessEngine -ArgumentList '/quiet', '/norestart' -Wait

Get-VerifiedFile -Uri $PosArtifactUri -Path $posPackage -ExpectedSha256 $PosArtifactSha256
Remove-Item -LiteralPath $appRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
Expand-Archive -LiteralPath $posPackage -DestinationPath $appRoot -Force
Get-VerifiedFile -Uri $DatabaseUri -Path $databasePath -ExpectedSha256 $DatabaseSha256

$iniPath = Join-Path $appRoot 'TailwindPOS.ini'
@"
[Connection String]
DatabaseConnectionString = Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$databasePath;Persist Security Info=False;

[Products]
ProductsWebAPIURL = $CatalogBaseUrl

[POS]
POSTerminal = 1

[CashDrawer]
MinimumCash = 300
"@ | Set-Content -LiteralPath $iniPath -Encoding Ascii

Import-Module WebAdministration
if (Test-Path "IIS:\AppPools\$appPoolName") {
    Remove-WebAppPool -Name $appPoolName
}
New-WebAppPool -Name $appPoolName | Out-Null
Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name managedRuntimeVersion -Value ''
Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name processModel.identityType -Value ApplicationPoolIdentity
Stop-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
if (Test-Path 'IIS:\Sites\TailwindPOS') {
    Remove-Website -Name 'TailwindPOS'
}
New-Website -Name 'TailwindPOS' -Port 80 -PhysicalPath $appRoot -ApplicationPool $appPoolName | Out-Null
& icacls $appRoot /grant "IIS AppPool\$appPoolName:(OI)(CI)M" /T

Start-Website -Name 'TailwindPOS'