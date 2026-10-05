$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot "monitorar_backups.config.json"
$defaultReportDirectory = Join-Path $env:ProgramData "InovaFarma\MonitoramentoBackup"

function Get-Config {
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Arquivo de configuracao nao encontrado: $configPath"
    }

    return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}

function Get-BackupRoots([object]$config) {
    $roots = [System.Collections.Generic.List[object]]::new()

    function Add-Root([string]$path, [string]$origin) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Container) -and -not @($roots | Where-Object Path -eq $path)) {
            [void]$roots.Add([PSCustomObject]@{ Path = $path; Origem = $origin })
        }
    }

    $serviceRoot = if ($config.ServiceBackupRoot) { $config.ServiceBackupRoot } else { Join-Path $config.InovaFarmaRoot "BACKUP" }
    Add-Root $serviceRoot "service"

    if ($config.BackupRoot) {
        Add-Root $config.BackupRoot "manual"
    }

    foreach ($manualRoot in @($config.ManualBackupRoots)) {
        Add-Root ([string]$manualRoot) "manual"
    }

    if ($roots.Count -eq 0) {
        $destinationFile = Join-Path $config.InovaFarmaRoot "DestinoBackup.txt"
        if (Test-Path -LiteralPath $destinationFile) {
            Add-Root ((Get-Content -LiteralPath $destinationFile -Raw).Trim()) "manual"
        }
    }

    if ($roots.Count -eq 0) {
        throw "Nenhum destino de backup encontrado. Verifique ServiceBackupRoot ou ManualBackupRoots."
    }

    return $roots.ToArray()
}

function Find-Executable([string]$name, [string[]]$fallbacks) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($fallback in $fallbacks) {
        if (Test-Path -LiteralPath $fallback -PathType Leaf) {
            return $fallback
        }
    }

    return $null
}

function Test-CompressedBackup([System.IO.FileInfo]$file, [string]$sevenZipPath) {
    if (-not $sevenZipPath) {
        return @{ Status = "nao_verificado"; Detalhe = "7za.exe nao encontrado" }
    }

    $output = @(& $sevenZipPath t $file.FullName -y 2>&1 | ForEach-Object { $_.ToString() })
    $text = $output -join "`n"
    $hasSuccess = $text -match "Everything is Ok"
    $hasFatalError = $text -match "Data Error|CRC Failed|Unexpected end|Can not open the file as"

    if ($hasSuccess -and -not ($hasFatalError -and $text -notmatch "file is open as")) {
        return @{ Status = "ok"; Detalhe = ($output | Select-Object -Last 5) -join " | " }
    }

    return @{ Status = "invalido"; Detalhe = ($output | Select-Object -Last 8) -join " | " }
}

function Test-SqlBackup([System.IO.FileInfo]$file, [string]$sqlServer, [string]$osqlPath) {
    if (-not $osqlPath) {
        return @{ Status = "nao_verificado"; Detalhe = "osql.exe nao encontrado" }
    }

    $escapedPath = $file.FullName.Replace("'", "''")
    $output = @(& $osqlPath -S $sqlServer -E -Q "RESTORE VERIFYONLY FROM DISK = N'$escapedPath' WITH CHECKSUM" -b 2>&1 | ForEach-Object { $_.ToString() })
    $text = $output -join "`n"
    if ($LASTEXITCODE -eq 0 -and $text -match "backup set on file .* is valid") {
        return @{ Status = "ok"; Detalhe = ($output | Select-Object -Last 4) -join " | " }
    }

    if ($text -match "does not\s+contain checksum information") {
        $output = @(& $osqlPath -S $sqlServer -E -Q "RESTORE VERIFYONLY FROM DISK = N'$escapedPath'" -b 2>&1 | ForEach-Object { $_.ToString() })
        $text = $output -join "`n"
        if ($LASTEXITCODE -eq 0 -and $text -match "backup set on file .* is valid") {
            return @{ Status = "ok"; Detalhe = "Valido; backup original nao possui checksum. " + (($output | Select-Object -Last 3) -join " | ") }
        }
    }

    return @{ Status = "invalido"; Detalhe = ($output | Select-Object -Last 8) -join " | " }
}

function Get-ReplicationResult([System.IO.FileInfo]$source, [object]$config) {
    $paths = @($config.ReplicationPaths | Where-Object { $_ -and $_.ToString().Trim() })
    if ($paths.Count -eq 0) {
        return @(@{ Destino = $null; Status = "nao_configurado"; Detalhe = "Nenhum terminal configurado" })
    }

    $results = @()
    foreach ($path in $paths) {
        $target = Join-Path $path $source.Name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $results += @{ Destino = $path; Status = "ausente"; Detalhe = $target }
            continue
        }

        $targetFile = Get-Item -LiteralPath $target
        if ($targetFile.Length -eq $source.Length) {
            $results += @{ Destino = $path; Status = "ok"; Detalhe = "Nome e tamanho conferem" }
        } else {
            $results += @{ Destino = $path; Status = "incompleto"; Detalhe = "Tamanho diferente" }
        }
    }

    return $results
}

function Get-BackupRecord([System.IO.FileInfo]$file, [object]$config, [string]$sevenZipPath, [string]$osqlPath, [string]$origin) {
    $validation = switch ($file.Extension.ToLowerInvariant()) {
        ".bak" {
            if ($config.ValidateSqlBackups) {
                Test-SqlBackup $file $config.SqlServer $osqlPath
            } else {
                @{ Status = "nao_verificado"; Detalhe = "Validacao SQL desativada" }
            }
        }
        ".zip" { Test-CompressedBackup $file $sevenZipPath }
        ".7z" { Test-CompressedBackup $file $sevenZipPath }
        ".rar" { Test-CompressedBackup $file $sevenZipPath }
        ".001" { Test-CompressedBackup $file $sevenZipPath }
        default { @{ Status = "nao_verificado"; Detalhe = "Extensao nao suportada" } }
    }

    [PSCustomObject]@{
        Nome = $file.Name
        Caminho = $file.FullName
        Tipo = if ($file.Name -match "\.(zip|7z|rar)\.\d{3}$") { $Matches[1].ToUpperInvariant() + " segmentado" } else { $file.Extension.TrimStart('.').ToUpperInvariant() }
        Origem = $origin
        UltimaAlteracao = $file.LastWriteTime
        TamanhoBytes = $file.Length
        Validacao = $validation.Status
        DetalheValidacao = $validation.Detalhe
        Replicacoes = @(Get-ReplicationResult $file $config)
    }
}

$config = Get-Config
$backupRoots = @(Get-BackupRoots $config)
$sevenZipPath = if ($config.SevenZipPath -and (Test-Path -LiteralPath $config.SevenZipPath)) { $config.SevenZipPath } else { $null }
$osqlPath = Find-Executable "osql.exe" @(
    "C:\Program Files (x86)\Microsoft SQL Server\140\Tools\Binn\OSQL.EXE",
    "C:\Program Files (x86)\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\SQLCMD.EXE"
)

$extensions = @(".bak", ".zip", ".7z", ".rar", ".001")
$fileEntries = @()
foreach ($backupRoot in $backupRoots) {
    $files = @(Get-ChildItem -LiteralPath $backupRoot.Path -File -Force -Recurse -ErrorAction Stop | Where-Object {
        $isSegmentedArchive = $_.Name -match "\.(zip|7z|rar)\.\d{3}$"
        (($extensions -contains $_.Extension.ToLowerInvariant()) -or $isSegmentedArchive) -and $_.Name -like $config.BackupNamePattern
    })
    foreach ($file in $files) {
        $fileEntries += [PSCustomObject]@{ File = $file; Origem = $backupRoot.Origem }
    }
}
$records = @($fileEntries | Sort-Object { $_.File.LastWriteTime } -Descending | ForEach-Object {
    Get-BackupRecord $_.File $config $sevenZipPath $osqlPath $_.Origem
})

$now = Get-Date
$latest = $records | Select-Object -First 1
$ageHours = if ($latest) { [math]::Round(($now - [datetime]$latest.UltimaAlteracao).TotalHours, 2) } else { $null }
$latestIsRecent = $latest -and $ageHours -le [double]$config.MaxAgeHours
$hasInvalid = @($records | Where-Object { $_.Validacao -eq "invalido" }).Count -gt 0
$overallStatus = if (-not $latest) { "sem_backup" } elseif (-not $latestIsRecent) { "atrasado" } elseif ($hasInvalid) { "invalido" } else { "ok" }

$report = [PSCustomObject]@{
    ClienteId = if ($config.ClientId) { $config.ClientId } else { $env:COMPUTERNAME }
    ClienteNome = if ($config.ClientName) { $config.ClientName } else { $env:COMPUTERNAME }
    Cnpj = if ($config.Cnpj) { $config.Cnpj } else { "" }
    NomeLoja = if ($config.NomeLoja) { $config.NomeLoja } else { if ($config.ClientName) { $config.ClientName } else { $env:COMPUTERNAME } }
    Responsavel = if ($config.Responsavel) { $config.Responsavel } else { "" }
    GeradoEm = $now
    Servidor = $env:COMPUTERNAME
    DestinoAnalisado = (($backupRoots | ForEach-Object { $_.Path }) -join "; ")
    Status = $overallStatus
    UltimoBackup = if ($latest) { $latest.UltimaAlteracao } else { $null }
    IdadeUltimoBackupHoras = $ageHours
    BackupsEncontrados = $records.Count
    OrigemAutomaticoManual = "Nao e possivel distinguir automaticamente nesta etapa; o servico nao grava essa informacao no nome do arquivo."
    Arquivos = $records
}

$reportDirectory = if ($config.ReportDirectory) { $config.ReportDirectory } else { $defaultReportDirectory }
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
$reportJson = $report | ConvertTo-Json -Depth 8
$reportJson | Set-Content -LiteralPath (Join-Path $reportDirectory "ultimo-relatorio.json") -Encoding UTF8

if ($config.CentralApiUrl) {
    try {
        $headers = @{}
        if ($config.CentralApiToken) {
            $headers["X-Monitor-Token"] = $config.CentralApiToken
        }
        Invoke-RestMethod -Uri $config.CentralApiUrl -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($reportJson)) -ContentType "application/json; charset=utf-8" -Headers $headers -TimeoutSec 20 | Out-Null
        Write-Output "Relatorio enviado ao central: $($config.CentralApiUrl)"
    } catch {
        Write-Warning "Nao foi possivel enviar o relatorio ao central: $($_.Exception.Message)"
    }
} else {
    Write-Warning "CentralApiUrl nao configurada; o relatorio foi salvo apenas neste computador."
}

Write-Output "Status: $overallStatus"
Write-Output "Destino: $(($backupRoots | ForEach-Object { $_.Path }) -join '; ')"
Write-Output "Arquivos encontrados: $($records.Count)"
if ($latest) {
    Write-Output "Ultimo backup: $($latest.Nome) - $($latest.UltimaAlteracao)"
}
foreach ($record in $records) {
    Write-Output "$($record.Validacao) | $($record.Tipo) | $($record.Nome)"
}