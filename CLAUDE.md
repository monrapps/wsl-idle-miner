# WSL Idle Miner

CLI automation in Windows PowerShell and Python, with no external dependencies.

- `prl-idle.ps1` monitors Windows activity, applies Afterburner profiles, and manages the `PRL-Idle-Miner` task.
- `prl-idle-worker.py` supervises the process group of the external script passed through `--script`. EOF or ten seconds without messages stops the miner.
- `prl-idle.sh` invokes PowerShell from WSL and resolves symbolic links to locate the project.
- `prl-idle.example.json` is the versioned template; `prl-idle.json` contains local paths and must never be committed. Do not version binaries, wallets, pool settings, or logs.

Validation: `python3 -m unittest discover -s tests -v` and `bash -n prl-idle.sh`. Tests must use simulated processes and temporary directories, without starting mining or changing real profiles.

When integrating through `ProcessStartInfo.Arguments`, this WSL installation rejects quotes around the distribution name. The distribution and user are validated and passed without quotes; worker and script paths are quoted.

The installer copies PowerShell and JSON files to `%LOCALAPPDATA%\PRLIdleMiner\`; repository changes must be propagated to that installation. Preserve user-defined profiles and always stop the miner before requesting the normal-use profile.

Project documentation, comments, CLI messages, and logs are in English. The installer also recognizes the legacy Portuguese task description so existing installations can be upgraded.
