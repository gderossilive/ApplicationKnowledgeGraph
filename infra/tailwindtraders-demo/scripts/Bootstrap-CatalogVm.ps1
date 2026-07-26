[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$CatalogArtifactUri,
    [Parameter(Mandatory = $true)] [string]$CatalogArtifactSha256
)

$ErrorActionPreference = 'Stop'
$appRoot = 'C:\TailwindDemo\catalog'
$packagePath = 'C:\TailwindDemo\catalog.zip'
$taskName = 'TailwindTradersDemoCatalog'

New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
Invoke-WebRequest -Uri $CatalogArtifactUri -OutFile $packagePath
$actualSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
if ($actualSha256 -ne $CatalogArtifactSha256.ToUpperInvariant()) {
    throw "Checksum validation failed for '$CatalogArtifactUri'."
}

Expand-Archive -LiteralPath $packagePath -DestinationPath $appRoot -Force
$stubPath = Join-Path $appRoot 'CatalogStub.ps1'
$catalogPath = Join-Path $appRoot 'catalog.json'
if (-not ((Test-Path -LiteralPath $stubPath) -and (Test-Path -LiteralPath $catalogPath))) {
    throw 'The catalog artifact must contain CatalogStub.ps1 and catalog.json at its root.'
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$stubPath`" -CatalogPath `"$catalogPath`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $taskName