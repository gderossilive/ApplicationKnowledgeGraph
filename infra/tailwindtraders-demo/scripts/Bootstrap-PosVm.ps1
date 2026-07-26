[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$PosSourceArchiveUri,
    [Parameter(Mandatory = $true)] [string]$PosSourceArchiveSha256,
    [Parameter(Mandatory = $true)] [string]$PosBuildSdkUri,
    [Parameter(Mandatory = $true)] [string]$PosBuildSdkSha512,
    [Parameter(Mandatory = $true)] [string]$CatalogBaseUrl,
    [Parameter(Mandatory = $true)] [string]$AspNetCoreHostingBundleUri,
    [Parameter(Mandatory = $true)] [string]$SqlServerHost,
    [Parameter(Mandatory = $true)] [string]$SqlDatabaseName,
    [Parameter(Mandatory = $true)] [string]$SqlAppUsername,
    [Parameter(Mandatory = $true)] [string]$SqlAppPasswordBase64
)

$ErrorActionPreference = 'Stop'
$appRoot = 'C:\inetpub\TailwindPOS'
$packageRoot = 'C:\TailwindDemo\packages'
$artifactRoot = 'C:\TailwindDemo\artifacts'
$sourceRoot = 'C:\TailwindDemo\source'
$publishRoot = 'C:\TailwindDemo\publish'
$appPoolName = 'TailwindPOS'

function Get-VerifiedFile {
    param([string]$Uri, [string]$Path, [string]$ExpectedHash, [string]$Algorithm = 'SHA256')

    Invoke-WebRequest -Uri $Uri -OutFile $Path
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
    if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
        throw "Checksum validation failed for '$Uri'."
    }
}

New-Item -ItemType Directory -Force -Path $packageRoot, $artifactRoot | Out-Null
Install-WindowsFeature -Name Web-Server, Web-Asp-Net45 -IncludeManagementTools | Out-Null

$hostingBundle = Join-Path $packageRoot 'dotnet-hosting.exe'
$sourcePackage = Join-Path $packageRoot 'TailwindPOS-source.zip'
$sdkInstaller = Join-Path $packageRoot 'dotnet-sdk-2.2.207-win-x64.exe'
$posPackage = Join-Path $artifactRoot 'TailwindPOS.zip'

Invoke-WebRequest -Uri $AspNetCoreHostingBundleUri -OutFile $hostingBundle
Start-Process -FilePath $hostingBundle -ArgumentList '/quiet', '/norestart' -Wait

Get-VerifiedFile -Uri $PosSourceArchiveUri -Path $sourcePackage -ExpectedHash $PosSourceArchiveSha256
Get-VerifiedFile -Uri $PosBuildSdkUri -Path $sdkInstaller -ExpectedHash $PosBuildSdkSha512 -Algorithm SHA512
Start-Process -FilePath $sdkInstaller -ArgumentList '/install', '/quiet', '/norestart' -Wait
Remove-Item -LiteralPath $sourceRoot, $publishRoot -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $sourcePackage -DestinationPath $sourceRoot -Force
$projectPath = Get-ChildItem -LiteralPath $sourceRoot -Filter 'TailwindPOS.csproj' -Recurse | Select-Object -First 1 -ExpandProperty FullName
if ($null -eq $projectPath) {
    throw 'TailwindPOS.csproj was not found in the source archive.'
}

& 'C:\Program Files\dotnet\dotnet.exe' publish $projectPath --configuration Release --output $publishRoot
if ($LASTEXITCODE -ne 0) {
    throw "TailwindPOS publish failed with exit code $LASTEXITCODE."
}
Remove-Item -LiteralPath $posPackage -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $publishRoot '*') -DestinationPath $posPackage -Force

Remove-Item -LiteralPath $appRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
Expand-Archive -LiteralPath $posPackage -DestinationPath $appRoot -Force

$iniPath = Join-Path $appRoot 'TailwindPOS.ini'
$sqlConnectionBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$sqlConnectionBuilder.DataSource = "tcp:$SqlServerHost,1433"
$sqlConnectionBuilder.InitialCatalog = $SqlDatabaseName
$sqlConnectionBuilder.UserID = $SqlAppUsername
$sqlConnectionBuilder.Password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SqlAppPasswordBase64))
$sqlConnectionBuilder.Encrypt = $true
$sqlConnectionBuilder.TrustServerCertificate = $true
$sqlConnectionBuilder.PersistSecurityInfo = $false
@"
[Connection String]
DatabaseConnectionString = $($sqlConnectionBuilder.ConnectionString)

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
& icacls $appRoot /grant "IIS AppPool\${appPoolName}:(OI)(CI)M" /T
& icacls $iniPath /inheritance:r
& icacls $iniPath /grant:r "IIS AppPool\${appPoolName}:(R)" 'BUILTIN\Administrators:(F)' 'SYSTEM:(F)'

Start-Website -Name 'TailwindPOS'