# Contexto do projeto de monitoramento

## Objetivo

Monitorar, no servidor de cada cliente, se os backups do InovaFarma foram gerados, se estao inteiros e, futuramente, se foram replicados para terminais da rede.

Este projeto e independente do InovaInstall. Nao existe vinculo entre os dois neste momento.

## Ambiente analisado

- Pasta do sistema: `C:\InovaFarma`
- Servico ativo observado: `InovaFarmaAPI.Service`
- SQL Server observado: instancia `SQL2016`
- Ferramenta de compactacao usada pelo sistema: `C:\InovaFarma\InovaFarmaAPI\7z\7za.exe`
- Arquivo que informa o destino dos backups: `C:\InovaFarma\DestinoBackup.txt`
- Destino observado inicialmente: `C:\TEMP`
- Destino real usado pelas tarefas do InovaFarma: `C:\InovaFarma\BACKUP`, organizado em subpastas por cliente e dia da semana.
- Backups manuais podem ser adicionados opcionalmente em `ManualBackupRoots`; essa lista pode permanecer vazia.

## Padrao encontrado

Foram encontrados arquivos `INOVAFARMA*.BAK`, arquivos compactados com extensao `.zip` e arquivos segmentados como `.zip.001`. Alguns arquivos `.zip` sao, na realidade, arquivos 7z com extensao alterada. Por isso a validacao deve usar o `7za.exe` do proprio InovaFarma, e nao presumir que a extensao representa o formato interno. A busca precisa ser recursiva porque o servico organiza os backups em subpastas.

Backups SQL sao validados com `RESTORE VERIFYONLY`. Backups antigos podem nao possuir checksum; nesses casos o monitor tenta novamente sem `WITH CHECKSUM` e registra essa limitacao.

## Arquivos do projeto

- `monitorar_backups.ps1`: executa a verificacao e gera o relatorio.
- `monitorar_backups.config.json`: configura destino, idade maxima, SQL Server, 7-Zip e terminais.
- `servidor_central.ps1`: recebe relatorios de varios clientes e alimenta o painel central.
- `instalar_monitor_cliente.ps1`: gera a configuracao local e registra a tarefa agendada automaticamente.
- `monitoramento-backup.html`: interface para listar clientes e consultar seus detalhes.
- `MONITORAMENTO_BACKUP.md`: instrucoes de uso.
- `CONTEXTO_PROJETO.md`: este resumo.

Relatorio gerado em:

`C:\ProgramData\InovaFarma\MonitoramentoBackup\ultimo-relatorio.json`

## Estado atual

O monitor foi executado com sucesso na maquina analisada:

- Apos a execucao da tarefa `BACKUP - 06:00`, 3 arquivos foram encontrados em `C:\InovaFarma\BACKUP`.
- 3 arquivos foram validados como inteiros.
- Estado geral observado: `ok`.
- Nenhum terminal foi configurado em `ReplicationPaths`.
- A verificacao de replicacao compara nome e tamanho do arquivo no destino configurado.
- A arquitetura multi-cliente agora permite que cada servidor envie seu relatorio ao central por HTTP.

## Limitacoes conhecidas

1. Ainda nao e possivel distinguir automaticamente backup automatico de backup manual. Os nomes dos arquivos observados nao carregam essa informacao.
2. E necessario descobrir no `InovaFarma Service` o log ou registro que informa a origem do backup.
3. Os caminhos dos terminais ainda precisam ser informados em `monitorar_backups.config.json`, por exemplo:

```json
"ReplicationPaths": [
  "\\\\TERMINAL01\\Backups",
  "\\\\TERMINAL02\\Backups"
]
```

4. A verificacao atual de replica confirma presenca e tamanho. Uma etapa posterior pode comparar hash e usar arquivo temporario durante a copia.
5. Ainda nao existe alerta por e-mail ou WhatsApp; o painel e a API central foram adicionados.

## Proximos passos sugeridos

1. Identificar logs do `InovaFarmaAPI.Service` relacionados a backup.
2. Configurar um terminal de teste em `ReplicationPaths`.
3. Criar tarefa agendada do Windows para executar o script diariamente.
4. Adicionar alertas quando o estado for `atrasado`, `sem_backup`, `invalido` ou `ausente`.
5. Instalar o agente nos clientes, definir `ClientId` unico e configurar o endereco do servidor central.
6. Criar alertas quando o estado for `atrasado`, `sem_backup`, `invalido` ou `offline`.
