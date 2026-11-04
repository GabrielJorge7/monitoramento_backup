# Instalador do Monitoramento de Backups

Este pacote instala o monitor em um computador cliente. Ele nao inclui o servidor central, o painel web, o banco de dados ou dependencias do Node.js.

## Arquivos

- `instalar_monitor_cliente.ps1`: abre a interface, gera a configuracao e cria as tarefas agendadas.
- `monitorar_backups.ps1`: verifica os backups e envia o relatorio ao central.
- `atualizar_monitor_cliente.ps1`: atualiza campos novos da configuracao sem apagar os dados da loja.

Mantenha os tres arquivos na mesma pasta.

## Requisitos

- Windows com Windows PowerShell 5.1.
- PowerShell executado como Administrador.
- `C:\InovaFarma` instalado no computador cliente.
- Acesso HTTPS ao servidor central.
- O token configurado em `MONITOR_TOKEN` no Render.

## Instalacao grafica

1. Copie a pasta `instalador_cliente` para o computador cliente, por exemplo:

   `C:\Monitoramento_Backup`

2. Abra o PowerShell como Administrador.

3. Entre na pasta:

   ```powershell
   cd C:\Monitoramento_Backup
   ```

4. Se os arquivos foram baixados da internet, desbloqueie-os:

   ```powershell
   Unblock-File .\*.ps1
   ```

5. Execute o instalador:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\instalar_monitor_cliente.ps1
   ```

6. Preencha a URL da API, o token central, CNPJ, loja e responsavel.

7. Opcionalmente, clique em `Configurar nuvem` e informe a pasta local sincronizada pelo OneDrive, Google Drive ou MEGA. Se a loja nao usa nuvem, deixe como `Nenhuma`.

8. Mantenha marcada a opcao para criar a tarefa agendada e executar agora.

9. Clique em `Instalar`.

## Instalacao por comando

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\instalar_monitor_cliente.ps1 `
  -CentralApiUrl "https://monitoramento-backup.onrender.com/api/report" `
  -CentralApiToken "SEU_MONITOR_TOKEN" `
  -Cnpj "12345678000199" `
  -NomeLoja "Farmacia Central" `
  -Responsavel "Nome do responsavel"
```

## O que sera criado

O instalador gera `monitorar_backups.config.json` na mesma pasta e registra:

- `Monitoramento Backup InovaFarma`: executa o monitor no intervalo configurado, normalmente a cada 30 minutos.
- `Atualizar Configuracao Monitoramento InovaFarma`: consulta o modelo de configuracao ao iniciar o Windows.

O primeiro relatorio e executado ao final da instalacao. Depois, confira o painel:

`https://monitoramento-backup.onrender.com/`

## Teste manual

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\monitorar_backups.ps1
```

A mensagem esperada inclui:

```text
Relatorio enviado ao central
```

Para conferir a tarefa:

```powershell
Get-ScheduledTask -TaskName "Monitoramento Backup InovaFarma"
```

Para executar a tarefa imediatamente:

```powershell
Start-ScheduledTask -TaskName "Monitoramento Backup InovaFarma"
```

## Observacoes

- Nao copie `monitorar_backups.config.json` do computador de desenvolvimento para outros clientes. O instalador gera uma configuracao nova.
- Nao coloque o token em arquivos enviados ao GitHub.
- Se o cliente nao usa nuvem, nenhuma configuracao adicional e necessaria.
- Para remover o monitor, desabilite ou exclua as duas tarefas agendadas e remova a pasta local.
