[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$AdminUsername,
    [Parameter(Mandatory = $true)] [string]$AdminPasswordBase64,
    [Parameter(Mandatory = $true)] [string]$SqlAdminPasswordBase64,
    [Parameter(Mandatory = $true)] [string]$SqlAppPasswordBase64,
    [Parameter(Mandatory = $true)] [string]$SchemaScriptSha256,
    [Parameter(Mandatory = $true)] [string]$SeedScriptSha256,
    [switch]$RunAsAdmin
)

$ErrorActionPreference = 'Stop'
$databaseName = 'TailwindPOS'
$appLogin = 'tailwindpos_app'
$sqlServiceName = 'MSSQLSERVER'

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

if (-not $RunAsAdmin) {
    $taskName = 'TailwindDemo-InitializeSql'
    $adminPassword = Get-DecodedSecret $AdminPasswordBase64
    $taskArguments = @(
        '-NoProfile',
        '-ExecutionPolicy Bypass',
        "-File `"$PSCommandPath`"",
        '-RunAsAdmin',
        "-AdminUsername `"$AdminUsername`"",
        "-AdminPasswordBase64 `"$AdminPasswordBase64`"",
        "-SqlAdminPasswordBase64 `"$SqlAdminPasswordBase64`"",
        "-SqlAppPasswordBase64 `"$SqlAppPasswordBase64`"",
        "-SchemaScriptSha256 `"$SchemaScriptSha256`"",
        "-SeedScriptSha256 `"$SeedScriptSha256`""
    ) -join ' '
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArguments
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -User ".\$AdminUsername" -Password $adminPassword -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

    try {
        for ($attempt = 1; $attempt -le 600; $attempt++) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
            if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') {
                if ($taskInfo.LastTaskResult -ne 0) {
                    throw "SQL initialization task failed with exit code $($taskInfo.LastTaskResult)."
                }
                exit 0
            }
            Start-Sleep -Seconds 2
        }
        throw 'SQL initialization task timed out after 20 minutes.'
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

$instanceId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').MSSQLSERVER
if ([string]::IsNullOrWhiteSpace($instanceId)) {
    throw 'The SQL Server 2017 Developer Marketplace image did not register its default instance.'
}
$tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
Set-ItemProperty -LiteralPath $tcpPath -Name Enabled -Value 1
Set-ItemProperty -LiteralPath "$tcpPath\IPAll" -Name TcpDynamicPorts -Value ''
Set-ItemProperty -LiteralPath "$tcpPath\IPAll" -Name TcpPort -Value '1433'
Restart-Service -Name $sqlServiceName -Force

$marketplaceConnectionString = 'Server=localhost;Initial Catalog=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connection Timeout=15'
for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        [void](Get-SqlScalar -ConnectionString $marketplaceConnectionString -CommandText 'SELECT 1;')
        break
    }
    catch {
        if ($attempt -eq 30) {
            throw
        }
        Start-Sleep -Seconds 2
    }
}

$escapedAdminPassword = $sqlAdminPassword.Replace("'", "''")
Invoke-SqlText -ConnectionString $marketplaceConnectionString -CommandText "ALTER LOGIN [sa] ENABLE; ALTER LOGIN [sa] WITH PASSWORD = N'$escapedAdminPassword';"
$adminConnectionString = "Server=localhost;Initial Catalog=master;User ID=sa;Password=$sqlAdminPassword;Encrypt=True;TrustServerCertificate=True;Connection Timeout=15"

if ($null -eq (Get-SqlScalar -ConnectionString $adminConnectionString -CommandText "SELECT DB_ID(N'$databaseName');")) {
    Invoke-SqlText -ConnectionString $adminConnectionString -CommandText "CREATE DATABASE [$databaseName] COLLATE SQL_Latin1_General_CP1_CI_AS;"
}

$databaseConnectionString = "Server=localhost;Initial Catalog=$databaseName;User ID=sa;Password=$sqlAdminPassword;Encrypt=True;TrustServerCertificate=True;Connection Timeout=15"
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