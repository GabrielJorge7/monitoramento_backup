[CmdletBinding()]
param(
    [string]$CentralApiUrl,
    [string]$CentralApiToken = "",
    [string]$ClientName = "",
    [string]$Cnpj = "",
    [string]$NomeLoja = "",
    [string]$Responsavel = "",
    [int]$IntervaloMinutos = 30,
    [switch]$NaoCriarTarefa,
    [switch]$Interface
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot "monitorar_backups.config.json"
$monitorScript = Join-Path $scriptRoot "monitorar_backups.ps1"
$updaterScript = Join-Path $scriptRoot "atualizar_monitor_cliente.ps1"
$inovaRoot = "C:\InovaFarma"
$computerName = $env:COMPUTERNAME
$clientId = ($computerName.ToLowerInvariant() -replace "[^a-z0-9._-]", "-")
$resolvedClientName = if ($ClientName) { $ClientName } else { $computerName }
$sevenZipPath = Join-Path $inovaRoot "InovaFarmaAPI\7z\7za.exe"
$destinationFile = Join-Path $inovaRoot "DestinoBackup.txt"
$powershellPath = (Get-Command powershell.exe).Source
$backupRoot = ""

function Show-SetupForm {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Instalar monitoramento de backups"
    $form.Size = New-Object System.Drawing.Size(560, 510)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Configurar computador cliente"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $title.AutoSize = $true
    $form.Controls.Add($title)

    $fields = @(
        @{ Key = "CentralApiUrl"; Label = "URL da API central"; Value = $CentralApiUrl; Secret = $false },
        @{ Key = "CentralApiToken"; Label = "Token central"; Value = $CentralApiToken; Secret = $true },
        @{ Key = "Cnpj"; Label = "CNPJ"; Value = $Cnpj; Secret = $false },
        @{ Key = "NomeLoja"; Label = "Nome da loja"; Value = $NomeLoja; Secret = $false },
        @{ Key = "Responsavel"; Label = "Responsavel"; Value = $Responsavel; Secret = $false }
    )
    $controls = @{}
    $top = 72
    foreach ($field in $fields) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $field.Label
        $label.Location = New-Object System.Drawing.Point(24, $top)
        $label.AutoSize = $true
        $form.Controls.Add($label)

        $input = New-Object System.Windows.Forms.TextBox
        $input.Location = New-Object System.Drawing.Point(190, ($top - 4))
        $input.Size = New-Object System.Drawing.Size(330, 24)
        $input.Text = [string]$field.Value
        if ($field.Secret) { $input.UseSystemPasswordChar = $true }
        $form.Controls.Add($input)
        $controls[$field.Key] = $input
        $top += 54
    }

    $intervalLabel = New-Object System.Windows.Forms.Label
    $intervalLabel.Text = "Intervalo (minutos)"
    $intervalLabel.Location = New-Object System.Drawing.Point(24, $top)
    $intervalLabel.AutoSize = $true
    $form.Controls.Add($intervalLabel)
    $intervalInput = New-Object System.Windows.Forms.NumericUpDown
    $intervalInput.Location = New-Object System.Drawing.Point(190, ($top - 4))
    $intervalInput.Size = New-Object System.Drawing.Size(100, 24)
    $intervalInput.Minimum = 5
    $intervalInput.Maximum = 1440
    $intervalInput.Value = $IntervaloMinutos
    $form.Controls.Add($intervalInput)

    $createTask = New-Object System.Windows.Forms.CheckBox
    $createTask.Text = "Criar tarefa agendada e executar agora"
    $createTask.Checked = -not $NaoCriarTarefa
    $createTask.Location = New-Object System.Drawing.Point(190, ($top + 40))
    $createTask.AutoSize = $true
    $form.Controls.Add($createTask)

    $install = New-Object System.Windows.Forms.Button
    $install.Text = "Instalar"
    $install.Location = New-Object System.Drawing.Point(190, ($top + 78))
    $install.Size = New-Object System.Drawing.Size(120, 34)
    $install.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($install)
    $form.AcceptButton = $install

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancelar"
    $cancel.Location = New-Object System.Drawing.Point(320, ($top + 78))
    $cancel.Size = New-Object System.Drawing.Size(120, 34)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
    if ([string]::IsNullOrWhiteSpace($controls.CentralApiUrl.Text) -or [string]::IsNullOrWhiteSpace($controls.CentralApiToken.Text)) {
        [System.Windows.Forms.MessageBox]::Show("URL da API e token sao obrigatorios.", "Dados incompletos", "OK", "Warning") | Out-Null
        return $false
    }
    $script:CentralApiUrl = $controls.CentralApiUrl.Text.Trim()
    $script:CentralApiToken = $controls.CentralApiToken.Text
    $script:Cnpj = $controls.Cnpj.Text.Trim()
    $script:NomeLoja = $controls.NomeLoja.Text.Trim()
    $script:Responsavel = $controls.Responsavel.Text.Trim()
    $script:IntervaloMinutos = [int]$intervalInput.Value
    $script:NaoCriarTarefa = -not $createTask.Checked
    return $true
}

if ($Interface -or [string]::IsNullOrWhiteSpace($CentralApiUrl)) {
    if (-not (Show-SetupForm)) { exit 0 }
}

if (Test-Path -LiteralPath $destinationFile -PathType Leaf) {
    $candidate = (Get-Content -LiteralPath $destinationFile -Raw).Trim()
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
        $backupRoot = $candidate
    }
}

if (-not (Test-Path -LiteralPath $monitorScript -PathType Leaf)) {
    throw "monitorar_backups.ps1 nao encontrado em $scriptRoot"
}

if (-not (Test-Path -LiteralPath $updaterScript -PathType Leaf)) {
    throw "atualizar_monitor_cliente.ps1 nao encontrado em $scriptRoot"
}

$config = [ordered]@{
    ConfigVersion = 1
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
    $monitorTaskName = "Monitoramento Backup InovaFarma"
    $monitorTaskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`""
    $monitorAction = New-ScheduledTaskAction -Execute $powershellPath -Argument $monitorTaskArguments
    $monitorTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervaloMinutos)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $monitorTaskName -Action $monitorAction -Trigger $monitorTrigger -Principal $principal -Force | Out-Null

    $updateTaskName = "Atualizar Configuracao Monitoramento InovaFarma"
    $updateTaskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$updaterScript`""
    $updateAction = New-ScheduledTaskAction -Execute $powershellPath -Argument $updateTaskArguments
    $updateTrigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName $updateTaskName -Action $updateAction -Trigger $updateTrigger -Principal $principal -Force | Out-Null
    Write-Output "Tarefa agendada: $monitorTaskName (a cada $IntervaloMinutos minuto(s))"
    Write-Output "Tarefa agendada: $updateTaskName (ao iniciar; no maximo uma vez por dia)"
}

& $powershellPath -NoProfile -ExecutionPolicy Bypass -File $monitorScript
