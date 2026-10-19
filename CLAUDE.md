# WSL Idle Miner

CLI automation in Windows PowerShell and Python, with no external dependencies.

- `idle-miner.ps1` monitors Windows activity, applies Afterburner profiles, and manages the `WSL-Idle-Miner` task.
- `idle-miner-worker.py` supervises the process group of the external script passed through `--script`. EOF or ten seconds without messages stops the miner. The optional `--miner-executable` argument detects manually started instances of a configured binary; the JSON setting is `miner_executable`.
- `idle-miner.sh` invokes PowerShell from WSL and resolves symbolic links to locate the project.
- `idle-miner.example.json` is the versioned template; `idle-miner.json` contains local paths and must never be committed. Do not version binaries, wallets, pool settings, or logs.

Validation: `python3 -m unittest discover -s tests -v` and `bash -n idle-miner.sh`. Tests must use simulated processes and temporary directories, without starting mining or changing real profiles.

When integrating through `ProcessStartInfo.Arguments`, this WSL installation rejects quotes around the distribution name. The distribution and user are validated and passed without quotes; worker and script paths are quoted.

The installer copies PowerShell and JSON files to `%LOCALAPPDATA%\WSLIdleMiner\`; repository changes must be propagated to that installation. The Linux worker stores logs and its lock in `~/.cache/wsl-idle-miner/`. Preserve user-defined profiles and always stop the miner before requesting the normal-use profile. When migrating older installations, stop and remove the previous task before starting the renamed task to prevent duplicate monitors.

Project documentation, comments, CLI messages, and logs are in English. Names and defaults must remain independent of any coin or miner vendor; the external script chooses the coin, algorithm, wallet, and pool.
