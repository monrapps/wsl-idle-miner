# WSL Idle Miner

Inicia um minerador no WSL quando a sessão do Windows fica sem atividade de teclado ou mouse. Ao detectar atividade, encerra o minerador e carrega o perfil de uso normal do MSI Afterburner.

A configuração de exemplo espera **15 minutos**, aplica o **perfil 2** do Afterburner e aguarda **3 segundos** antes de iniciar a mineração. Ao voltar a usar o PC, aplica o **perfil 1** depois de encerrar o minerador. Esses valores são configuráveis.

## Requisitos

- Windows com Windows PowerShell 5.1, Agendador de Tarefas e MSI Afterburner.
- Uma distribuição WSL com Bash, Python 3 e acesso ao minerador.
- Perfis de mineração e uso normal salvos no Afterburner, incluindo os ajustes das ventoinhas.
- Um script externo que inicia o minerador. Este repositório não inclui binário, carteira ou configuração de pool.

## Configuração

No WSL, dentro do repositório:

```bash
cp prl-idle.example.json prl-idle.json
```

Edite `prl-idle.json`:

| Campo | Valor |
| --- | --- |
| `idle_minutes` | Minutos sem atividade antes de iniciar. |
| `distribution` | Nome da distribuição mostrado por `wsl.exe --list --quiet`. |
| `linux_user` | Usuário que executará o minerador no WSL. |
| `worker` | Caminho absoluto de `prl-idle-worker.py` dentro do WSL. |
| `miner_script` | Caminho absoluto do seu script de mineração dentro do WSL. |
| `afterburner` | Caminho do executável do Afterburner no Windows. |
| `afterburner_mode` | `Profile` para carregar um perfil; `Open` para apenas abrir o programa se necessário. |
| `mining_profile` | Número do perfil de mineração, entre 1 e 5. |
| `normal_profile` | Número do perfil de uso normal, ou `null` para manter os ajustes. |
| `settle_seconds` | Espera após aplicar o perfil, de 0 a 5 segundos. |

O arquivo local `prl-idle.json` é ignorado pelo Git. Ele aponta para o script externo; carteira, pool e parâmetros do minerador permanecem nesse script.

O supervisor executa o script com Bash, tendo como diretório de trabalho a pasta do próprio script. Para que os sinais cheguem diretamente ao minerador, prefira `exec` no último comando:

```bash
#!/bin/bash
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
exec ./SEU-MINERADOR argumentos...
```

## Uso

```bash
./prl-idle.sh Check       # Verificar ociosidade e instalacao do Afterburner
./prl-idle.sh Run         # Executar em primeiro plano; Ctrl+C encerra
./prl-idle.sh Install     # Configurar inicializacao no logon do Windows
./prl-idle.sh Start       # Iniciar agora a tarefa instalada
./prl-idle.sh Status      # Consultar estado e local dos logs
./prl-idle.sh Stop        # Parar agora; preserva a inicializacao no proximo logon
./prl-idle.sh Uninstall   # Parar e remover a inicializacao automatica
```

`Install` pede uma confirmação de UAC para registrar a tarefa **PRL-Idle-Miner** com as permissões necessárias ao Afterburner. A tarefa executa na sessão interativa do usuário, sem senha salva e sem precisar abrir o terminal.

O instalador copia o monitor e a configuração para `%LOCALAPPDATA%\PRLIdleMiner\`. O supervisor Python continua no repositório WSL, e o minerador continua no caminho configurado em `miner_script`. Preserve esses caminhos enquanto a tarefa estiver instalada.

Após alterar a configuração ou atualizar o código, use `Stop`, `Install` e `Start` para atualizar os arquivos usados pela tarefa.

## Comportamento e recuperação

- A atividade é consultada a cada segundo. A medição corresponde à [sessão do Windows que executa o monitor](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getlastinputinfo).
- Ao parar, o supervisor envia SIGTERM ao grupo do minerador. Após dois segundos, usa SIGKILL para encerrar processos remanescentes.
- Se a conexão com o Windows fechar ou passar dez segundos sem mensagens, o supervisor encerra a mineração.
- Após uma falha, o monitor permite nova tentativa em 60 segundos.
- Um mutex no Windows e um lock no Linux bloqueiam monitores duplicados.
- Se um SRBMiner já estiver rodando manualmente **a partir da mesma pasta do script configurado**, o monitor aguarda sem alterar os clocks. Essa detecção usa o executável `SRBMiner-MULTI`; outros mineradores dependem da própria proteção contra duplicação.
- Se o monitor for finalizado à força, o supervisor encerra o minerador; o perfil de uso normal será solicitado quando o monitor reiniciar. Use `Stop` para encerrar e restaurar o perfil normalmente.

A ausência de teclado e mouse também conta como ociosidade ao assistir a um vídeo. O monitor não impede suspensão, hibernação ou desligamento do PC. A confirmação do comando do Afterburner não verifica os clocks e a rotação efetivamente aplicados pelo driver.

## Logs

- Monitor: `%LOCALAPPDATA%\PRLIdleMiner\monitor.log`.
- Estado: `%LOCALAPPDATA%\PRLIdleMiner\state.json`.
- Saída do minerador: `~/.cache/prl-idle/miner.log`, no WSL. O arquivo anterior é rotacionado antes de uma nova sessão quando ultrapassa 5 MiB.

## Testes

Os testes usam processos simulados, sem executar o minerador nem alterar clocks:

```bash
python3 -m unittest discover -s tests -v
bash -n prl-idle.sh
```

A integração completa com Windows, Afterburner e Agendador de Tarefas precisa ser validada em uma máquina Windows/WSL.
