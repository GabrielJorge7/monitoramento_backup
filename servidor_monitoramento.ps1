param(
    [int]$Port = 8787,
    [int]$IntervaloMinutos = 5
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$monitorScript = Join-Path $scriptRoot "monitorar_backups.ps1"
$dashboardPath = Join-Path $scriptRoot "monitoramento-backup.html"
$configPath = Join-Path $scriptRoot "monitorar_backups.config.json"
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$reportDirectory = if ($config.ReportDirectory) { $config.ReportDirectory } else { Join-Path $env:ProgramData "InovaFarma\MonitoramentoBackup" }
$reportPath = Join-Path $reportDirectory "ultimo-relatorio.json"

function Write-Response([System.Net.HttpListenerResponse]$response, [int]$statusCode, [string]$contentType, [string]$body) {
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($body)
    $response.StatusCode = $statusCode
    $response.ContentType = $contentType
    $response.ContentEncoding = [System.Text.Encoding]::UTF8
    $response.ContentLength64 = $buffer.Length
    $response.AddHeader("Cache-Control", "no-store")
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.Close()
}

function Get-Report {
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
}

function Update-Report {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitorScript *> $null
    return Get-Report
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host "Dashboard: http://localhost:$Port/"
Write-Host "Atualizacao automatica: a cada $IntervaloMinutos minuto(s)."
Write-Host "Pressione Ctrl+C para encerrar."

$lastRun = [datetime]::MinValue
while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
        $path = $context.Request.Url.AbsolutePath
        if ($path -eq "/") {
            $html = Get-Content -LiteralPath $dashboardPath -Raw
            Write-Response $context.Response 200 "text/html; charset=utf-8" $html
            continue
        }

        if ($path -eq "/api/status") {
            $report = Get-Report
            if (-not $report -or ((Get-Date) - $lastRun).TotalMinutes -ge $IntervaloMinutos) {
                $report = Update-Report
                $lastRun = Get-Date
            }

            if ($report) {
                $json = $report | ConvertTo-Json -Depth 8 -Compress
                Write-Response $context.Response 200 "application/json; charset=utf-8" $json
            } else {
                Write-Response $context.Response 503 "application/json; charset=utf-8" '{"erro":"Relatorio ainda nao foi gerado."}'
            }
            continue
        }

        Write-Response $context.Response 404 "text/plain; charset=utf-8" "Nao encontrado"
    } catch {
        if ($context.Response.OutputStream.CanWrite) {
            $body = @{ erro = $_.Exception.Message } | ConvertTo-Json -Compress
            Write-Response $context.Response 500 "application/json; charset=utf-8" $body
        }
    }
}
