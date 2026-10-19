param(
    [ValidateSet('Run', 'Install', 'Start', 'Stop', 'Status', 'Uninstall', 'Check')]
    [string]$Action = 'Status',
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$taskName = 'PRL-Idle-Miner'
$dataDir = Join-Path $env:LOCALAPPDATA 'PRLIdleMiner'
$installedScript = Join-Path $dataDir 'prl-idle.ps1'
$installedConfig = Join-Path $dataDir 'prl-idle.json'
$statePath = Join-Path $dataDir 'state.json'
$stopPath = Join-Path $dataDir 'stop'
$profileMarker = Join-Path $dataDir 'mining-profile-active'
if (-not $ConfigPath) {
    if ($Action -ne 'Install' -and (Test-Path -LiteralPath $installedConfig)) {
        $ConfigPath = $installedConfig
    } else {
        $ConfigPath = Join-Path $PSScriptRoot 'prl-idle.json'
    }
}
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath (Join-Path $dataDir 'monitor.log') -Value $line -Encoding UTF8
}

function Read-State {
    if (Test-Path -LiteralPath $statePath) {
        try { return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch {}
    }
    return $null
}

function Get-MonitorProcess {
    $state = Read-State
    if ($state -and $state.monitor_pid) {
        $process = Get-Process -Id $state.monitor_pid -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime.ToUniversalTime().ToString('o') -eq $state.started) {
            return $process
        }
    }
    return $null
}

function Stop-Monitor {
    $monitor = Get-MonitorProcess
    if ($monitor) {
        New-Item -ItemType File -Path $stopPath -Force | Out-Null
        if (-not $monitor.WaitForExit(15000)) {
            throw 'The monitor did not confirm shutdown. Check monitor.log.'
        }
    }
}

function Initialize-IdleApi {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class PrlWindowsIdle {
    [StructLayout(LayoutKind.Sequential)]
    struct LastInput { public uint size; public uint time; }
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool GetLastInputInfo(ref LastInput info);
    [DllImport("kernel32.dll")]
    static extern uint GetTickCount();
    public static double Seconds() {
        var info = new LastInput();
        info.size = (uint)Marshal.SizeOf(info);
        if (!GetLastInputInfo(ref info)) throw new Win32Exception();
        return unchecked(GetTickCount() - info.time) / 1000.0;
    }
}
'@
}

function Assert-Config {
    if ($cfg.afterburner_mode -notin @('Open', 'Profile')) {
        throw 'Set afterburner_mode to Open or Profile before running.'
    }
    if ($cfg.idle_minutes -lt 1 -or $cfg.settle_seconds -lt 0 -or $cfg.settle_seconds -gt 5) {
        throw 'Idle time must be positive and settle_seconds must be between 0 and 5.'
    }
    if ($cfg.afterburner_mode -eq 'Profile' -and $cfg.mining_profile -notin 1..5) {
        throw 'The mining profile must be a number from 1 to 5.'
    }
    if ($null -ne $cfg.normal_profile -and $cfg.normal_profile -notin 1..5) {
        throw 'The normal-use profile must be a number from 1 to 5 or null.'
    }
    if (-not (Test-Path -LiteralPath $cfg.afterburner)) { throw 'MSI Afterburner not found.' }
    foreach ($argument in @($cfg.worker, $cfg.miner_script)) {
        if ([string]::IsNullOrWhiteSpace($argument) -or -not $argument.StartsWith('/') -or $argument -match '["\r\n]') {
            throw 'Set worker and miner_script to absolute WSL paths, without quotes or line breaks.'
        }
    }
    if ($cfg.distribution -notmatch '^[A-Za-z0-9_.-]+$' -or $cfg.linux_user -notmatch '^[A-Za-z0-9_.-]+$') {
        throw 'WSL distribution and user names must contain only letters, numbers, dots, hyphens, or underscores.'
    }
}

switch ($Action) {
    'Check' {
        Initialize-IdleApi
        [pscustomobject]@{
            IdleSeconds = [PrlWindowsIdle]::Seconds()
            IdleMinutesRequired = $cfg.idle_minutes
            AfterburnerInstalled = Test-Path -LiteralPath $cfg.afterburner
            AfterburnerRunning = [bool](Get-Process MSIAfterburner -ErrorAction SilentlyContinue)
            MiningProfile = $cfg.mining_profile
            NormalProfile = $cfg.normal_profile
        } | ConvertTo-Json
        exit 0
    }
    'Status' {
        $state = Read-State
        [pscustomobject]@{
            MonitorRunning = [bool](Get-MonitorProcess)
            ScheduledTask = [string](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
            ConfigPath = $ConfigPath
            State = $state
            Logs = $dataDir
        } | ConvertTo-Json -Depth 4
        exit 0
    }
    'Stop' { Stop-Monitor; Write-Output 'Monitor and automatic mining stopped.'; exit 0 }
    'Uninstall' {
        Stop-Monitor
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        Write-Output 'Automatic startup removed. Configuration and logs preserved.'
        exit 0
    }
    'Install' {
        Assert-Config
        if ($PSCommandPath -ne $installedScript) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
        }
        if ((Resolve-Path -LiteralPath $ConfigPath).Path -ne $installedConfig) {
            Copy-Item -LiteralPath $ConfigPath -Destination $installedConfig -Force
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            # Elevating once during installation allows Afterburner to run
            # without another UAC prompt on each idle cycle.
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Install -ConfigPath "{1}"' -f $installedScript, $installedConfig
            $setup = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -PassThru -Wait
            if ($setup.ExitCode -ne 0) { throw 'The elevated installation did not complete.' }
            exit 0
        }
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        # Accept the legacy Portuguese description when upgrading an existing task.
        if ($existing -and $existing.Description -notin @('PRL idle mining with MSI Afterburner.', 'Mineracao PRL por ociosidade com MSI Afterburner.')) {
            throw 'A task with this name and a different description already exists; it has been preserved.'
        }
        $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Run -ConfigPath "{1}"' -f $installedScript, $installedConfig
        $taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description 'PRL idle mining with MSI Afterburner.' -Force | Out-Null
        Write-Output "Task $taskName installed. Use Start to activate it now."
        exit 0
    }
    'Start' {
        if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
            throw 'Install first with ./prl-idle.sh Install, or use Run in the foreground.'
        }
        Start-ScheduledTask -TaskName $taskName
        Write-Output 'Monitor started in the background.'
        exit 0
    }
}

Assert-Config

$mutex = New-Object Threading.Mutex($false, 'Local\PRLIdleMiner')
try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { $mutex.Dispose(); throw 'The monitor is already running in this session.' }
$script:worker = $null
$script:workerErrors = $null
$script:profileChanged = Test-Path -LiteralPath $profileMarker
$script:mining = $false
$started = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
$retryAt = [DateTime]::MinValue

function Read-Worker {
    $read = $script:worker.StandardOutput.ReadLineAsync()
    if (-not $read.Wait(30000)) { throw 'No response from the WSL worker.' }
    if ($null -eq $read.Result) { throw 'The WSL worker closed the connection.' }
    try { $answer = $read.Result | ConvertFrom-Json } catch {
        throw "Invalid response from WSL: $($read.Result.Replace([string][char]0, ''))"
    }
    if (-not $answer.ok) { throw $answer.error }
    return $answer
}

function Send-Worker([string]$Command) {
    $script:worker.StandardInput.WriteLine($Command)
    $script:worker.StandardInput.Flush()
    return Read-Worker
}

function Open-Worker {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = "$env:SystemRoot\System32\wsl.exe"
    $info.Arguments = '--distribution {0} --user {1} --exec /usr/bin/python3 "{2}" --script "{3}"' -f $cfg.distribution, $cfg.linux_user, $cfg.worker, $cfg.miner_script
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $script:worker = [Diagnostics.Process]::Start($info)
    $script:workerErrors = $script:worker.StandardError.ReadToEndAsync()
    return Read-Worker
}

function Close-Worker {
    if ($script:worker) {
        try { $script:worker.StandardInput.Close() } catch {}
        # EOF also stops the miner. If the pipe stalls, the Linux watchdog
        # terminates the group after ten seconds without messages.
        if (-not $script:worker.WaitForExit(12000)) {
            Write-Log 'WSL did not confirm shutdown; waiting for the Linux watchdog.'
            $script:worker.Kill()
        }
        if ($script:workerErrors.IsCompleted -and $script:workerErrors.Result) {
            Write-Log $script:workerErrors.Result.Trim()
        }
        $script:worker.Dispose()
        $script:worker = $null
    }
    $script:mining = $false
}

function Apply-Afterburner([int]$Profile) {
    $parameters = @{ FilePath = $cfg.afterburner; PassThru = $true }
    if ($Profile) { $parameters.ArgumentList = "-profile$Profile" }
    $application = Start-Process @parameters
    if ($application.WaitForExit(1000) -and $application.ExitCode -ne 0) {
        throw "Afterburner returned error $($application.ExitCode)."
    }
}

function Restore-Profile {
    if ($script:profileChanged -and $null -ne $cfg.normal_profile) {
        Apply-Afterburner $cfg.normal_profile
        Write-Log "Requested normal-use profile $($cfg.normal_profile)."
    }
    $script:profileChanged = $false
    Remove-Item -LiteralPath $profileMarker -Force -ErrorAction SilentlyContinue
}

try {
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    Initialize-IdleApi
    Write-Log "Monitor started: $($cfg.idle_minutes) minutes; mining profile $($cfg.mining_profile), normal-use profile $($cfg.normal_profile)."
    while (-not (Test-Path -LiteralPath $stopPath)) {
        $idle = [PrlWindowsIdle]::Seconds()
        try {
            if ($idle -lt $cfg.idle_minutes * 60) {
                if ($script:worker) {
                    Send-Worker 'stop' | Out-Null
                    Close-Worker
                    Write-Log 'Activity detected. Mining stopped.'
                }
                Restore-Profile
            } elseif (-not $script:worker -and (Get-Date) -ge $retryAt) {
                $ready = Open-Worker
                if ($ready.other_miner) { throw 'A manual miner is already running; waiting without changing clock settings.' }
                if ($cfg.afterburner_mode -eq 'Profile') {
                    $script:profileChanged = $true
                    New-Item -ItemType File -Path $profileMarker -Force | Out-Null
                    Apply-Afterburner $cfg.mining_profile
                } elseif (-not (Get-Process MSIAfterburner -ErrorAction SilentlyContinue)) {
                    Apply-Afterburner 0
                    $script:profileChanged = $true
                }
                # The user may resume activity while WSL/Afterburner is starting.
                # Keep the watchdog alive while clock settings settle.
                for ($i = 0; $i -lt $cfg.settle_seconds; $i++) {
                    Send-Worker 'status' | Out-Null
                    Start-Sleep -Seconds 1
                    if ([PrlWindowsIdle]::Seconds() -lt $cfg.idle_minutes * 60 -or (Test-Path -LiteralPath $stopPath)) { break }
                }
                if ([PrlWindowsIdle]::Seconds() -ge $cfg.idle_minutes * 60 -and -not (Test-Path -LiteralPath $stopPath)) {
                    $answer = Send-Worker 'start'
                    $script:mining = $answer.running
                    Write-Log "Mining started, Linux PID $($answer.pid)."
                } else {
                    Close-Worker
                    Restore-Profile
                }
            } elseif ($script:worker) {
                $answer = Send-Worker 'status'
                if (-not $answer.running) { throw 'The miner exited; retrying in 60 seconds.' }
                if (-not (Get-Process MSIAfterburner -ErrorAction SilentlyContinue)) {
                    throw 'Afterburner exited; stopping mining.'
                }
            }
        } catch {
            Write-Log "Error: $($_.Exception.Message)"
            Close-Worker
            try { Restore-Profile } catch { Write-Log "Failed to restore profile: $($_.Exception.Message)" }
            $retryAt = (Get-Date).AddSeconds(60)
        }
        @{
            monitor_pid = $PID; started = $started
            mining = $script:mining; idle_seconds = [Math]::Round($idle, 1)
            idle_minutes_required = $cfg.idle_minutes
            mining_profile = $cfg.mining_profile; normal_profile = $cfg.normal_profile
            updated = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath "$statePath.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$statePath.tmp" -Destination $statePath -Force
        Start-Sleep -Seconds 1
    }
} finally {
    Close-Worker
    try { Restore-Profile } catch { Write-Log "Failed to restore profile: $($_.Exception.Message)" }
    Write-Log 'Monitor stopped.'
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
