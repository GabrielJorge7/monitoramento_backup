[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "monitorar_backups.config.json"),
    [string]$TemplateUrl = "https://raw.githubusercontent.com/GabrielJorge7/monitoramento_backup/main/monitorar_backups.config.example.json",
    [string]$MonitorScriptPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "monitorar_backups.ps1"),
    [switch]$RunMonitor,
    [switch]$Forcar
)

$ErrorActionPreference = "Stop"
$updateMarkerPath = Join-Path $env:ProgramData "InovaFarma\MonitoramentoBackup\ultima-atualizacao-config.txt"

function Get-PropertyNames([object]$object) {
    return @($object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Is-Placeholder([object]$value) {
    if ($null -eq $value) { return $true }
    $text = [string]$value
    return [string]::IsNullOrWhiteSpace($text) -or $text -match "seu-|troque-|preencha-|example|exemplo"
}

try {
    $today = (Get-Date).ToString("yyyy-MM-dd")
    if (-not $Forcar -and (Test-Path -LiteralPath $updateMarkerPath -PathType Leaf) -and (Get-Content -LiteralPath $updateMarkerPath -Raw).Trim() -eq $today) {
        Write-Output "Configuracao ja consultada hoje ($today)."
        if ($RunMonitor -and (Test-Path -LiteralPath $MonitorScriptPath -PathType Leaf)) {
            $powershellPath = (Get-Command powershell.exe).Source
            & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $MonitorScriptPath
        }
        exit 0
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuracao local nao encontrada: $ConfigPath"
    }

    $localJson = Get-Content -LiteralPath $ConfigPath -Raw
    $localConfig = $localJson | ConvertFrom-Json
    $templateConfig = (Invoke-WebRequest -Uri $TemplateUrl -UseBasicParsing -TimeoutSec 20).Content | ConvertFrom-Json
    $localNames = @(Get-PropertyNames $localConfig)
    $added = @()

    foreach ($property in $templateConfig.PSObject.Properties) {
        if ($localNames -notcontains $property.Name -and -not (($property.Name -in @("CentralApiToken", "CentralApiUrl")) -and (Is-Placeholder $property.Value))) {
            $localConfig | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
            $added += $property.Name
        }
    }

    $localConfig | Add-Member -MemberType NoteProperty -Name "ConfigVersion" -Value ([int]$templateConfig.ConfigVersion) -Force
    $localConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    New-Item -ItemType Directory -Path (Split-Path -Parent $updateMarkerPath) -Force | Out-Null
    $today | Set-Content -LiteralPath $updateMarkerPath -Encoding ASCII
    Write-Output "Configuracao consultada no GitHub: $TemplateUrl"
    if ($added.Count -gt 0) { Write-Output "Campos adicionados: $($added -join ', ')" } else { Write-Output "Nenhum campo novo para adicionar." }
} catch {
    Write-Warning "Nao foi possivel atualizar a configuracao pelo GitHub: $($_.Exception.Message)"
}

if ($RunMonitor -and (Test-Path -LiteralPath $MonitorScriptPath -PathType Leaf)) {
    $powershellPath = (Get-Command powershell.exe).Source
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $MonitorScriptPath
}
