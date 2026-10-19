# WSL Idle Miner

Automação CLI em Windows PowerShell e Python, sem dependências externas.

- `prl-idle.ps1` mede atividade no Windows, aplica perfis do Afterburner e gerencia a tarefa `PRL-Idle-Miner`.
- `prl-idle-worker.py` supervisiona o grupo de processos do script externo informado em `--script`. EOF ou dez segundos sem mensagens encerram o minerador.
- `prl-idle.sh` chama o PowerShell a partir do WSL e resolve links simbólicos para encontrar o projeto.
- `prl-idle.example.json` é o modelo versionado; `prl-idle.json` contém caminhos locais e nunca deve ser commitado. Não versionar binários, carteiras, configurações de pool ou logs.

Verificação: `python3 -m unittest discover -s tests -v` e `bash -n prl-idle.sh`. Testes devem usar processos simulados e diretórios temporários, sem iniciar mineração nem alterar os perfis reais.

Na integração via `ProcessStartInfo.Arguments`, esta instalação do WSL rejeita aspas no nome da distribuição. Distribuição e usuário são validados e enviados sem aspas; os caminhos do worker e do script são enviados entre aspas.

O instalador copia PowerShell e JSON para `%LOCALAPPDATA%\PRLIdleMiner\`; alterações no repositório precisam ser propagadas para essa instalação. Preserve os perfis definidos pelo usuário e sempre encerre o minerador antes de solicitar o perfil de uso normal.
