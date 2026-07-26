[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$SqlServerBootstrapperUri,
    [Parameter(Mandatory = $true)] [string]$SqlServerBootstrapperSha256,
    [Parameter(Mandatory = $true)] [string]$SqlAdminPasswordBase64,
    [Parameter(Mandatory = $true)] [string]$SqlAppPasswordBase64,
    [Parameter(Mandatory = $true)] [string]$SchemaScriptSha256,
    [Parameter(Mandatory = $true)] [string]$SeedScriptSha256
)

$ErrorActionPreference = 'Stop'
$packageRoot = 'C:\TailwindDemo\packages'
$mediaRoot = 'C:\TailwindDemo\sql-media'
$databaseName = 'TailwindPOS'
$appLogin = 'tailwindpos_app'
$sqlInstance = 'SQLEXPRESS'

function Get-VerifiedFile {
    param([string]$Uri, [string]$Path, [string]$ExpectedHash)

    Invoke-WebRequest -Uri $Uri -OutFile $Path
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
        throw "Checksum validation failed for '$Uri'."
    }
}

function Assert-MicrosoftSignature {
    param([string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Microsoft Corporation') {
        throw "The Microsoft Authenticode signature validation failed for '$Path'."
    }
}

function Get-DecodedSecret {
    param([string]$Base64Value)

    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64Value))
}

function Invoke-SqlText {
    param([string]$ConnectionString, [string]$CommandText)

    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 120
        $command.CommandText = $CommandText
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

function Get-SqlScalar {
    param([string]$ConnectionString, [string]$CommandText)

    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 30
        $command.CommandText = $CommandText
        return $command.ExecuteScalar()
    }
    finally {
        $connection.Dispose()
    }
}

$sqlAdminPassword = Get-DecodedSecret $SqlAdminPasswordBase64
$sqlAppPassword = Get-DecodedSecret $SqlAppPasswordBase64
if ($sqlAdminPassword -match '["\r\n]') {
    throw 'sqlAdminPassword must not contain a double quote or a line break.'
}

New-Item -ItemType Directory -Force -Path $packageRoot, $mediaRoot | Out-Null
$downloadRoot = Join-Path $packageRoot 'sql-server-2017-download'
$bootstrapperPath = Join-Path $downloadRoot 'SQLServer2017-SSEI-Expr.exe'
Remove-Item -LiteralPath $downloadRoot, $mediaRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $downloadRoot, $mediaRoot | Out-Null
Get-VerifiedFile -Uri $SqlServerBootstrapperUri -Path $bootstrapperPath -ExpectedHash $SqlServerBootstrapperSha256
Assert-MicrosoftSignature -Path $bootstrapperPath

$downloadProcess = Start-Process -FilePath $bootstrapperPath -ArgumentList @(
    '/ACTION=Download',
    '/MEDIATYPE=Express',
    '/QUIET',
    "/MEDIAPATH=$downloadRoot"
) -Wait -PassThru
if ($downloadProcess.ExitCode -notin 0, 3010) {
    throw "SQL Server Express media download failed with exit code $($downloadProcess.ExitCode)."
}

$expressMedia = Get-ChildItem -LiteralPath $downloadRoot -Filter 'SQLEXPR*_x64_ENU.exe' -Recurse | Select-Object -First 1 -ExpandProperty FullName
if ($null -eq $expressMedia) {
    throw 'The SQL Server Express downloader did not create an x64 media executable.'
}
Assert-MicrosoftSignature -Path $expressMedia

$extractProcess = Start-Process -FilePath $expressMedia -ArgumentList @(
    "/x:$mediaRoot",
    '/Q'
) -Wait -PassThru
if ($extractProcess.ExitCode -notin 0, 3010) {
    throw "SQL Server Express media extraction failed with exit code $($extractProcess.ExitCode)."
}
$setupPath = Get-ChildItem -LiteralPath $mediaRoot -Filter 'setup.exe' -Recurse | Select-Object -First 1 -ExpandProperty FullName
if ($null -eq $setupPath) {
    throw 'The extracted SQL Server Express media does not contain setup.exe.'
}

$setupArguments = @(
    '/Q',
    '/ACTION=Install',
    '/FEATURES=SQLEngine',
    "/INSTANCENAME=$sqlInstance",
    '/SQLSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"',
    '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"',
    '/SECURITYMODE=SQL',
    "/SAPWD=\"$sqlAdminPassword\"",
    '/TCPENABLED=1',
    '/IACCEPTSQLSERVERLICENSETERMS'
)
$process = Start-Process -FilePath $setupPath -ArgumentList $setupArguments -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw "SQL Server setup failed with exit code $($process.ExitCode)."
}

$instanceId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$sqlInstance
if ([string]::IsNullOrWhiteSpace($instanceId)) {
    throw "SQL Server instance '$sqlInstance' was not registered."
}
$tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
Set-ItemProperty -LiteralPath $tcpPath -Name Enabled -Value 1
Set-ItemProperty -LiteralPath "$tcpPath\IPAll" -Name TcpDynamicPorts -Value ''
Set-ItemProperty -LiteralPath "$tcpPath\IPAll" -Name TcpPort -Value '1433'
Restart-Service -Name "MSSQL`$$sqlInstance" -Force

$adminConnectionString = "Server=localhost\$sqlInstance;Initial Catalog=master;User ID=sa;Password=$sqlAdminPassword;Encrypt=True;TrustServerCertificate=True;Connection Timeout=15"
for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        [void](Get-SqlScalar -ConnectionString $adminConnectionString -CommandText 'SELECT 1;')
        break
    }
    catch {
        if ($attempt -eq 30) {
            throw
        }
        Start-Sleep -Seconds 2
    }
}

if ($null -eq (Get-SqlScalar -ConnectionString $adminConnectionString -CommandText "SELECT DB_ID(N'$databaseName');")) {
    Invoke-SqlText -ConnectionString $adminConnectionString -CommandText "CREATE DATABASE [$databaseName] COLLATE SQL_Latin1_General_CP1_CI_AS;"
}

$databaseConnectionString = "Server=localhost\$sqlInstance;Initial Catalog=$databaseName;User ID=sa;Password=$sqlAdminPassword;Encrypt=True;TrustServerCertificate=True;Connection Timeout=15"
$schemaPath = Join-Path $PSScriptRoot 'Schema-TailwindPos.sql'
$seedPath = Join-Path $PSScriptRoot 'Seed-TailwindPos.sql'
foreach ($scriptFile in @(
    @{ Path = $schemaPath; Hash = $SchemaScriptSha256 },
    @{ Path = $seedPath; Hash = $SeedScriptSha256 }
)) {
    if (-not (Test-Path -LiteralPath $scriptFile.Path)) {
        throw "Database script '$($scriptFile.Path)' was not downloaded."
    }
    $actualHash = (Get-FileHash -LiteralPath $scriptFile.Path -Algorithm SHA256).Hash
    if ($actualHash -ne $scriptFile.Hash.ToUpperInvariant()) {
        throw "Checksum validation failed for '$($scriptFile.Path)'."
    }
    Invoke-SqlText -ConnectionString $databaseConnectionString -CommandText (Get-Content -LiteralPath $scriptFile.Path -Raw)
}

$escapedAppPassword = $sqlAppPassword.Replace("'", "''")
$appLoginSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$appLogin')
    CREATE LOGIN [$appLogin] WITH PASSWORD = N'$escapedAppPassword', CHECK_POLICY = ON;
USE [$databaseName];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$appLogin')
    CREATE USER [$appLogin] FOR LOGIN [$appLogin];
ALTER ROLE db_datareader ADD MEMBER [$appLogin];
ALTER ROLE db_datawriter ADD MEMBER [$appLogin];
"@
Invoke-SqlText -ConnectionString $adminConnectionString -CommandText $appLoginSql

New-NetFirewallRule -DisplayName 'Tailwind POS SQL Server from POS subnet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -RemoteAddress '10.42.1.0/24' -ErrorAction SilentlyContinue | Out-Null