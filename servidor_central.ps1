param(
    [int]$Port = 8787,
    [string]$Prefix = "http://+:8787/",
    [string]$StorageDirectory = (Join-Path $PSScriptRoot "clientes"),
    [string]$Token = "",
    [int]$OfflineMinutes = 15
)

$ErrorActionPreference = "Stop"
$dashboardPath = Join-Path $PSScriptRoot "monitoramento-backup.html"
New-Item -ItemType Directory -Path $StorageDirectory -Force | Out-Null

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

function Get-SafeFileName([string]$value) {
    $safe = $value -replace "[^a-zA-Z0-9._-]", "_"
    if (-not $safe) { throw "ClienteId invalido." }
    return $safe
}

function Get-ClientPath([string]$clientId) {
    return Join-Path $StorageDirectory ((Get-SafeFileName $clientId) + ".json")
}

function Read-Body([System.Net.HttpListenerRequest]$request) {
    $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-ClientEnvelope([string]$path) {
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-Clients {
    $now = Get-Date
    $clients = @()
    foreach ($path in @(Get-ChildItem -LiteralPath $StorageDirectory -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $envelope = Get-ClientEnvelope $path.FullName
        if (-not $envelope -or -not $envelope.Relatorio) { continue }
        try { $lastContact = [datetime]::Parse([string]$envelope.RecebidoEm) } catch { continue }
        $isOffline = (($now - $lastContact).TotalMinutes -gt $OfflineMinutes)
        $report = $envelope.Relatorio
        $clientStatus = if ($isOffline) { "offline" } else { [string]$report.Status }
        $clients += [PSCustomObject]@{
            ClienteId = [string]$report.ClienteId
            ClienteNome = [string]$report.ClienteNome
            Cnpj = [string]$report.Cnpj
            NomeLoja = if ($report.NomeLoja) { [string]$report.NomeLoja } else { [string]$report.ClienteNome }
            Responsavel = [string]$report.Responsavel
            Servidor = [string]$report.Servidor
            Status = $clientStatus
            StatusLocal = [string]$report.Status
            UltimoContato = $lastContact
            GeradoEm = $report.GeradoEm
            UltimoBackup = $report.UltimoBackup
            IdadeUltimoBackupHoras = $report.IdadeUltimoBackupHoras
            BackupsEncontrados = $report.BackupsEncontrados
        }
    }
    return @($clients | Sort-Object Status, ClienteNome)
}

function Get-StatusPayload {
    $clients = @(Get-Clients)
    return [PSCustomObject]@{
        GeradoEm = Get-Date
        Resumo = [PSCustomObject]@{
            Total = $clients.Count
            Ok = @($clients | Where-Object Status -eq "ok").Count
            Atrasados = @($clients | Where-Object Status -eq "atrasado").Count
            Invalidos = @($clients | Where-Object Status -eq "invalido").Count
            SemBackup = @($clients | Where-Object Status -eq "sem_backup").Count
            Offline = @($clients | Where-Object Status -eq "offline").Count
        }
        Clientes = $clients
    }
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Prefix)
$listener.Start()
Write-Host "Dashboard central: http://localhost:$Port/"
Write-Host "Prefixo de rede: $Prefix"
Write-Host "Clientes offline apos: $OfflineMinutes minuto(s)."
Write-Host "Pressione Ctrl+C para encerrar."

while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
        $path = $context.Request.Url.AbsolutePath.TrimEnd("/")
        if ($path -eq "") { $path = "/" }

        if ($path -eq "/") {
            Write-Response $context.Response 200 "text/html; charset=utf-8" (Get-Content -LiteralPath $dashboardPath -Raw)
            continue
        }

        if ($path -eq "/api/report" -and $context.Request.HttpMethod -eq "POST") {
            if ($Token -and $context.Request.Headers["X-Monitor-Token"] -ne $Token) {
                Write-Response $context.Response 401 "application/json; charset=utf-8" '{"erro":"Token invalido."}'
                continue
            }
            $report = Read-Body $context.Request | ConvertFrom-Json
            if (-not $report.ClienteId) { throw "O relatorio precisa informar ClienteId." }
            $envelope = [PSCustomObject]@{ RecebidoEm = (Get-Date).ToString("o"); Relatorio = $report }
            $envelope | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Get-ClientPath $report.ClienteId) -Encoding UTF8
            Write-Response $context.Response 200 "application/json; charset=utf-8" '{"recebido":true}'
            continue
        }

        if ($path -eq "/api/status" -and $context.Request.HttpMethod -eq "GET") {
            Write-Response $context.Response 200 "application/json; charset=utf-8" ((Get-StatusPayload) | ConvertTo-Json -Depth 8 -Compress)
            continue
        }

        if ($path -like "/api/client/*" -and $context.Request.HttpMethod -eq "GET") {
            $clientId = [System.Uri]::UnescapeDataString($path.Substring(12))
            $clientPath = Get-ClientPath $clientId
            if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf)) {
                Write-Response $context.Response 404 "application/json; charset=utf-8" '{"erro":"Cliente nao encontrado."}'
                continue
            }
            $envelope = Get-ClientEnvelope $clientPath
            Write-Response $context.Response 200 "application/json; charset=utf-8" (($envelope.Relatorio) | ConvertTo-Json -Depth 12 -Compress)
            continue
        }

        Write-Response $context.Response 404 "text/plain; charset=utf-8" "Nao encontrado"
    } catch {
        $body = @{ erro = $_.Exception.Message } | ConvertTo-Json -Compress
        if ($context.Response.OutputStream.CanWrite) { Write-Response $context.Response 500 "application/json; charset=utf-8" $body }
    }
}
