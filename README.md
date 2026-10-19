# WSL Idle Miner

Starts a miner in WSL when the Windows session has no keyboard or mouse activity. When activity resumes, it stops the miner and loads the normal-use MSI Afterburner profile.

The example configuration waits **15 minutes**, applies Afterburner **profile 2**, and waits **3 seconds** before starting mining. When you resume using the PC, it applies **profile 1** after stopping the miner. These values are configurable.

## Requirements

- Windows with Windows PowerShell 5.1, Task Scheduler, and MSI Afterburner.
- A WSL distribution with Bash, Python 3, and access to the miner.
- Mining and normal-use profiles saved in Afterburner, including fan settings.
- An external script that starts the miner. This repository does not include a miner binary, wallet, or pool configuration.

## Configuration

In WSL, from the repository directory:

```bash
cp prl-idle.example.json prl-idle.json
```

Edit `prl-idle.json`:

| Field | Value |
| --- | --- |
| `idle_minutes` | Minutes without activity before starting. |
| `distribution` | Distribution name shown by `wsl.exe --list --quiet`. |
| `linux_user` | User that runs the miner in WSL. |
| `worker` | Absolute path to `prl-idle-worker.py` inside WSL. |
| `miner_script` | Absolute path to your mining script inside WSL. |
| `afterburner` | Path to the Afterburner executable on Windows. |
| `afterburner_mode` | `Profile` to load a profile; `Open` to open the application only if needed. |
| `mining_profile` | Mining profile number, from 1 to 5. |
| `normal_profile` | Normal-use profile number, or `null` to keep the current settings. |
| `settle_seconds` | Delay after applying the profile, from 0 to 5 seconds. |

The local `prl-idle.json` file is ignored by Git. It points to the external script; the wallet, pool, and miner parameters stay in that script.

The worker runs the script with Bash, using the script's own directory as its working directory. To send signals directly to the miner, use `exec` for the final command:

```bash
#!/bin/bash
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
exec ./YOUR-MINER arguments...
```

## Usage

```bash
./prl-idle.sh Check       # Check idle time and Afterburner installation
./prl-idle.sh Run         # Run in the foreground; Ctrl+C stops it
./prl-idle.sh Install     # Set up automatic startup at Windows logon
./prl-idle.sh Start       # Start the installed task now
./prl-idle.sh Status      # Show status and log location
./prl-idle.sh Stop        # Stop now; keep automatic startup at the next logon
./prl-idle.sh Uninstall   # Stop and remove automatic startup
```

`Install` requests UAC confirmation to register the **PRL-Idle-Miner** task with the permissions Afterburner requires. The task runs in the user's interactive session, without storing a password or requiring an open terminal.

The installer copies the monitor and configuration to `%LOCALAPPDATA%\PRLIdleMiner\`. The Python worker remains in the WSL repository, and the miner stays at the path configured in `miner_script`. Keep those paths unchanged while the task is installed.

After changing the configuration or updating the code, use `Stop`, `Install`, and `Start` to update the files used by the task.

## Behavior and recovery

- Activity is checked every second. The measurement applies to the [Windows session running the monitor](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getlastinputinfo).
- When stopping, the worker sends SIGTERM to the miner's process group. After two seconds, it uses SIGKILL to terminate any remaining processes.
- If the connection to Windows closes or ten seconds pass without messages, the worker stops mining.
- After a failure, the monitor allows another attempt in 60 seconds.
- A Windows mutex and a Linux lock prevent duplicate monitors.
- If SRBMiner is already running manually **from the same directory as the configured script**, the monitor waits without changing clock settings. This detection uses the `SRBMiner-MULTI` executable; other miners rely on their own duplicate-instance protection.
- If the monitor is forcibly terminated, the worker stops the miner; the normal-use profile is requested when the monitor restarts. Use `Stop` to shut down and restore the profile normally.

Watching a video without keyboard or mouse input also counts as idle time. The monitor does not prevent the PC from sleeping, hibernating, or shutting down. A successful Afterburner command does not verify the clock settings and fan speeds actually applied by the driver.

## Logs

- Monitor: `%LOCALAPPDATA%\PRLIdleMiner\monitor.log`.
- State: `%LOCALAPPDATA%\PRLIdleMiner\state.json`.
- Miner output: `~/.cache/prl-idle/miner.log`, in WSL. The previous file is rotated before a new session when it exceeds 5 MiB.

## Tests

Tests use simulated processes, without running the miner or changing clock settings:

```bash
python3 -m unittest discover -s tests -v
bash -n prl-idle.sh
```

Full integration with Windows, Afterburner, and Task Scheduler must be validated on a Windows/WSL machine.
