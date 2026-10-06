# Monitoramento dos backups do InovaFarma

O script `monitorar_backups.ps1` verifica o servidor local sem alterar o `InovaFarma Service`.

## O que e verificado

- O destino automático do serviço em `C:\InovaFarma\BACKUP`, incluindo subpastas.
- Caminhos manuais opcionais informados em `ManualBackupRoots`.
- Arquivos `INOVAFARMA*.BAK`, `.zip`, `.7z` e `.rar`.
- Integridade de `.BAK` com `RESTORE VERIFYONLY` no SQL Server.
- Integridade de arquivos compactados com `C:\InovaFarma\InovaFarmaAPI\7z\7za.exe`.
- Idade do backup mais recente.
- Existencia e tamanho dos arquivos em terminais configurados.

## Executar

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\monitorar_backups.ps1
```

O relatorio fica em:

`C:\ProgramData\InovaFarma\MonitoramentoBackup\ultimo-relatorio.json`

## Configurar terminais

Edite `monitorar_backups.config.json` e informe as pastas de destino, por exemplo:

```json
"ReplicationPaths": [
  "\\\\TERMINAL01\\Backups",
  "\\\\TERMINAL02\\Backups"
]
```

O arquivo do terminal precisa ter o mesmo nome do arquivo do servidor e o mesmo tamanho. A origem automatica ou manual ainda nao e distinguida porque essa informacao nao esta presente no nome dos arquivos observados; para isso sera necessario integrar com o log ou com um registro do `InovaFarma Service`.

O campo `MaxAgeHours` define quando o estado passa para `atrasado`. O valor atual e 24 horas: o Service pode ficar sem gerar arquivo durante a janela normal entre 20:00 e 08:00, mas passa a ser considerado atrasado depois de um dia sem backup. Clientes antigos que ainda estejam no valor padrão 26 serão ajustados automaticamente para 24 pelo atualizador; valores personalizados são preservados.

### Backup manual opcional

O monitor sempre verifica os backups do serviço em `C:\InovaFarma\BACKUP`. Para incluir uma pasta onde os backups manuais são salvos, adicione caminhos em `ManualBackupRoots`:

```json
"ServiceBackupRoot": "C:\\InovaFarma\\BACKUP",
"ManualBackupRoots": [
  "D:\\BackupsManuais"
]
```

Essa configuração é opcional. Se `ManualBackupRoots` ficar vazio, somente os backups do serviço serão monitorados. Cada arquivo no relatório terá `Origem` como `service` ou `manual`.

## Monitoramento de varios clientes

O monitoramento e distribuido: cada servidor de cliente executa `monitorar_backups.ps1` localmente, usando os executaveis e caminhos daquele cliente. Depois ele envia somente o relatorio para um servidor central. O servidor central nao precisa ter InovaFarma, `7za.exe` ou SQL Server instalado.

### Configurar cada cliente

Em cada cliente, preencha os campos abaixo em `monitorar_backups.config.json`:

```json
{
  "ClientId": "cliente-001",
  "ClientName": "Farmacia Central",
  "Cnpj": "00.000.000/0001-00",
  "NomeLoja": "Farmacia Central",
  "Responsavel": "Nome do responsavel",
  "CentralApiUrl": "https://monitoramento-backup.onrender.com/api/report",
  "CentralApiToken": "troque-por-um-token"
}
```

Mantenha no restante da configuracao os caminhos locais de `InovaFarmaRoot`, `SevenZipPath`, `SqlServer` e `ReportDirectory`. O `ClientId` deve ser unico para cada cliente.

`Cnpj`, `NomeLoja` e `Responsavel` sao usados para pesquisa e filtragem no painel. O CNPJ pode ser informado com ou sem pontuacao.

Para evitar preencher esses dados manualmente, copie os arquivos do projeto para o cliente e execute apenas este comando como administrador:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\instalar_monitor_cliente.ps1 -CentralApiUrl "https://monitoramento-backup.onrender.com/api/report" -CentralApiToken "troque-por-um-token"
```

Tambem e possivel executar sem parametros para abrir a interface de instalacao:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\instalar_monitor_cliente.ps1
```

A janela solicita URL, token, CNPJ, nome da loja, responsavel e intervalo. Ao clicar em `Instalar`, ela substitui o `monitorar_backups.config.json`, cria a tarefa agendada e executa o primeiro monitoramento. A opcao `-Interface` abre a janela mesmo quando uma URL ja foi informada.

O instalador gera automaticamente `ClientId` a partir do nome do computador, usa o nome do computador como nome do cliente, detecta `C:\InovaFarma`, `7za.exe` e `DestinoBackup.txt`, cria o `monitorar_backups.config.json` e registra a tarefa `Monitoramento Backup InovaFarma` para executar a cada 30 minutos. Para preencher os dados comerciais durante a instalação, acrescente `-Cnpj`, `-NomeLoja` e `-Responsavel`. Para testar sem registrar a tarefa, acrescente `-NaoCriarTarefa`.

A instalacao cria duas tarefas agendadas separadas: `Monitoramento Backup InovaFarma`, que verifica e envia o relatorio a cada 30 minutos, e `Atualizar Configuracao Monitoramento InovaFarma`, que roda ao iniciar o Windows. O atualizador consulta o GitHub no maximo uma vez por dia, adiciona apenas campos novos e preserva os dados da loja. Se o GitHub estiver indisponivel, o monitor continua usando a configuracao local.

O status geral sempre representa o `ServiceBackupRoot`. Backups em `ManualBackupRoots` aparecem separados e nunca podem mascarar `sem_backup` ou `indisponivel` do Service. `nao_verificado` significa que o arquivo mais recente foi encontrado, mas o executavel de validacao nao estava disponivel. `suspeito_tamanho` aparece somente quando o arquivo mais recente da mesma origem e menor que o anterior; tamanho igual ou maior nao gera alerta.

O unico dado necessario no comando e o endereco do servidor central. O token deve ser o mesmo configurado no central.

Para executar manualmente o agente:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\monitorar_backups.ps1
```

### Iniciar o central

No computador que hospedara o painel, execute:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\servidor_central.ps1 -Token "troque-por-um-token"
```

Para clientes em outras redes, use a URL publica da Render em `CentralApiUrl`. O painel fica em `https://monitoramento-backup.onrender.com/`.

O painel atualiza a lista a cada 30 segundos. Um cliente passa para `OFFLINE` depois de 90 minutos sem enviar relatorio. Esse valor evita falso offline porque o agente envia a cada 30 minutos; na Render, use `OFFLINE_MINUTES=90`.

Na tela de clientes, use a pesquisa para localizar por CNPJ, loja, responsável, servidor ou identificador e use o filtro de status para separar clientes em dia, atrasados, inválidos, sem backup ou offline.

Para testes externos sem dominio proprio, o agente pode usar uma URL temporaria do Cloudflare Tunnel, por exemplo:

```json
"CentralApiUrl": "https://monitoramento-backup.onrender.com/api/report"
```

Essa URL so funciona enquanto o comando `cloudflared tunnel --url http://127.0.0.1:8788` estiver em execucao. Ao reiniciar o tunel, a URL pode mudar.

## Deploy na Render

O servidor central tambem possui uma versao Node.js para hospedagem na Render:

- `server.js`: API e painel central.
- `package.json`: comando de inicializacao.
- `package-lock.json`: dependencias fixadas.

Na criacao de um Web Service, use:

```text
Language: Node
Branch: main
Root Directory: vazio
Build Command: npm install
Start Command: npm start
```

Crie tambem um banco PostgreSQL na Render e associe a variavel `DATABASE_URL` ao Web Service. Sem banco, o servidor usa a pasta local `clientes`, que serve apenas para teste e pode ser perdida quando o servico reiniciar.

Adicione estas variaveis de ambiente no Web Service:

```text
MONITOR_TOKEN=gere-um-token-novo
OFFLINE_MINUTES=90
ADMIN_EMAIL=admin@suaempresa.com
ADMIN_PASSWORD=uma-senha-forte-com-8-ou-mais-caracteres
```

`ADMIN_EMAIL` e `ADMIN_PASSWORD` criam automaticamente o primeiro usuario administrador na primeira inicializacao do banco. Depois do primeiro acesso, o administrador pode abrir o botao `Usuarios` e criar contas de colaboradores ou outros administradores. Colaboradores podem consultar clientes, mas nao gerenciam contas.

Na tela `Usuarios`, o administrador pode ativar, desativar ou excluir contas. A listagem e as APIs de usuarios sao restritas ao perfil administrador; colaboradores nao conseguem visualizar essa area.

O login humano e separado do `MONITOR_TOKEN`: o token autentica os agentes instalados nos clientes, enquanto e-mail e senha autenticam os colaboradores do painel. O PostgreSQL armazena usuarios, senhas protegidas por hash e sessoes.

A Render fornecera uma URL semelhante a `https://monitoramento-backup.onrender.com`. Nos clientes, configure:

```json
"CentralApiUrl": "https://monitoramento-backup.onrender.com/api/report",
"CentralApiToken": "o-mesmo-valor-de-MONITOR_TOKEN"
```

O servidor Node escuta automaticamente a porta `PORT` fornecida pela Render e em `0.0.0.0`, como exigido pela plataforma.

O arquivo `monitorar_backups.config.json` e local de cada cliente e nao deve ser enviado ao Git. Use `monitorar_backups.config.example.json` como modelo. A pasta `clientes` e ignorada quando o servidor Node roda sem PostgreSQL; em producao, use `DATABASE_URL` para armazenar os relatorios no PostgreSQL.