[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CentralApiUrl,
    [string]$CentralApiToken = "",
    [string]$ClientName = "",
    [string]$Cnpj = "",
    [string]$NomeLoja = "",
    [string]$Responsavel = "",
    [int]$IntervaloMinutos = 30,
    [switch]$NaoCriarTarefa
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot "monitorar_backups.config.json"
$monitorScript = Join-Path $scriptRoot "monitorar_backups.ps1"
$inovaRoot = "C:\InovaFarma"
$computerName = $env:COMPUTERNAME
$clientId = ($computerName.ToLowerInvariant() -replace "[^a-z0-9._-]", "-")
$resolvedClientName = if ($ClientName) { $ClientName } else { $computerName }
$sevenZipPath = Join-Path $inovaRoot "InovaFarmaAPI\7z\7za.exe"
$destinationFile = Join-Path $inovaRoot "DestinoBackup.txt"
$powershellPath = (Get-Command powershell.exe).Source
$backupRoot = ""

if (Test-Path -LiteralPath $destinationFile -PathType Leaf) {
    $candidate = (Get-Content -LiteralPath $destinationFile -Raw).Trim()
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
        $backupRoot = $candidate
    }
}

if (-not (Test-Path -LiteralPath $monitorScript -PathType Leaf)) {
    throw "monitorar_backups.ps1 nao encontrado em $scriptRoot"
}

$config = [ordered]@{
    ClientId = $clientId
    ClientName = $resolvedClientName
    Cnpj = $Cnpj
    NomeLoja = if ($NomeLoja) { $NomeLoja } else { $resolvedClientName }
    Responsavel = $Responsavel
    CentralApiUrl = $CentralApiUrl.TrimEnd("/")
    CentralApiToken = $CentralApiToken
    InovaFarmaRoot = $inovaRoot
    ServiceBackupRoot = (Join-Path $inovaRoot "BACKUP")
    ManualBackupRoots = @()
    BackupRoot = ""
    BackupNamePattern = "INOVAFARMA*"
    MaxAgeHours = 26
    ValidateSqlBackups = $true
    SqlServer = ".\SQL2016"
    SevenZipPath = $sevenZipPath
    ReplicationPaths = @()
    ReportDirectory = (Join-Path $env:ProgramData "InovaFarma\MonitoramentoBackup")
}

$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
Write-Output "Configuracao gerada: $configPath"
Write-Output "Cliente: $resolvedClientName ($clientId)"
Write-Output "Destino detectado: $(if ($backupRoot) { $backupRoot } else { 'sera lido pelo monitor' })"
Write-Output "Central: $CentralApiUrl"

if (-not $NaoCriarTarefa) {
    $taskName = "Monitoramento Backup InovaFarma"
    $taskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`""
    $action = New-ScheduledTaskAction -Execute $powershellPath -Argument $taskArguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervaloMinutos)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Output "Tarefa agendada: $taskName (a cada $IntervaloMinutos minuto(s))"
}

& $powershellPath -NoProfile -ExecutionPolicy Bypass -File $monitorScript
