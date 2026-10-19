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
            throw 'O monitor nao confirmou a parada. Consulte monitor.log.'
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
        throw 'Escolha afterburner_mode Open ou Profile antes de executar.'
    }
    if ($cfg.idle_minutes -lt 1 -or $cfg.settle_seconds -lt 0 -or $cfg.settle_seconds -gt 5) {
        throw 'O tempo de ociosidade deve ser positivo e settle_seconds deve estar entre 0 e 5.'
    }
    if ($cfg.afterburner_mode -eq 'Profile' -and $cfg.mining_profile -notin 1..5) {
        throw 'O perfil de mineracao deve ser um numero de 1 a 5.'
    }
    if ($null -ne $cfg.normal_profile -and $cfg.normal_profile -notin 1..5) {
        throw 'O perfil de uso normal deve ser um numero de 1 a 5 ou null.'
    }
    if (-not (Test-Path -LiteralPath $cfg.afterburner)) { throw 'MSI Afterburner nao encontrado.' }
    foreach ($argument in @($cfg.worker, $cfg.miner_script)) {
        if ([string]::IsNullOrWhiteSpace($argument) -or -not $argument.StartsWith('/') -or $argument -match '["\r\n]') {
            throw 'Configure worker e miner_script com caminhos absolutos no WSL, sem aspas ou quebras de linha.'
        }
    }
    if ($cfg.distribution -notmatch '^[A-Za-z0-9_.-]+$' -or $cfg.linux_user -notmatch '^[A-Za-z0-9_.-]+$') {
        throw 'O nome da distribuicao e do usuario WSL devem conter apenas letras, numeros, ponto, hifen ou sublinhado.'
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
    'Stop' { Stop-Monitor; Write-Output 'Monitor e mineracao automatica encerrados.'; exit 0 }
    'Uninstall' {
        Stop-Monitor
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        Write-Output 'Inicializacao automatica removida. Configuracao e logs preservados.'
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
            # Uma unica elevacao no instalador permite usar o Afterburner sem
            # uma nova janela de UAC em cada ciclo de ociosidade.
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Install -ConfigPath "{1}"' -f $installedScript, $installedConfig
            $setup = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -PassThru -Wait
            if ($setup.ExitCode -ne 0) { throw 'A instalacao elevada nao foi concluida.' }
            exit 0
        }
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing -and $existing.Description -ne 'Mineracao PRL por ociosidade com MSI Afterburner.') {
            throw 'Ja existe uma tarefa com esse nome e outra descricao; ela foi preservada.'
        }
        $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Run -ConfigPath "{1}"' -f $installedScript, $installedConfig
        $taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description 'Mineracao PRL por ociosidade com MSI Afterburner.' -Force | Out-Null
        Write-Output "Tarefa $taskName instalada. Use Start para ativar agora."
        exit 0
    }
    'Start' {
        if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
            throw 'Instale primeiro com ./prl-idle.sh Install, ou execute Run no primeiro plano.'
        }
        Start-ScheduledTask -TaskName $taskName
        Write-Output 'Monitor iniciado em segundo plano.'
        exit 0
    }
}

Assert-Config

$mutex = New-Object Threading.Mutex($false, 'Local\PRLIdleMiner')
try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { $mutex.Dispose(); throw 'O monitor ja esta em execucao nesta sessao.' }
$script:worker = $null
$script:workerErrors = $null
$script:profileChanged = Test-Path -LiteralPath $profileMarker
$script:mining = $false
$started = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
$retryAt = [DateTime]::MinValue

function Read-Worker {
    $read = $script:worker.StandardOutput.ReadLineAsync()
    if (-not $read.Wait(30000)) { throw 'Sem resposta do supervisor WSL.' }
    if ($null -eq $read.Result) { throw 'O supervisor WSL encerrou a conexao.' }
    try { $answer = $read.Result | ConvertFrom-Json } catch {
        throw "Resposta invalida do WSL: $($read.Result.Replace([string][char]0, ''))"
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
        # EOF tambem encerra o minerador. Se o pipe travar, o watchdog Linux
        # encerra o grupo apos dez segundos sem mensagens.
        if (-not $script:worker.WaitForExit(12000)) {
            Write-Log 'WSL nao confirmou saida; aguardando watchdog Linux.'
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
        throw "Afterburner retornou erro $($application.ExitCode)."
    }
}

function Restore-Profile {
    if ($script:profileChanged -and $null -ne $cfg.normal_profile) {
        Apply-Afterburner $cfg.normal_profile
        Write-Log "Solicitado perfil de uso normal $($cfg.normal_profile)."
    }
    $script:profileChanged = $false
    Remove-Item -LiteralPath $profileMarker -Force -ErrorAction SilentlyContinue
}

try {
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    Initialize-IdleApi
    Write-Log "Monitor iniciado: $($cfg.idle_minutes) minutos; mineracao perfil $($cfg.mining_profile), uso normal perfil $($cfg.normal_profile)."
    while (-not (Test-Path -LiteralPath $stopPath)) {
        $idle = [PrlWindowsIdle]::Seconds()
        try {
            if ($idle -lt $cfg.idle_minutes * 60) {
                if ($script:worker) {
                    Send-Worker 'stop' | Out-Null
                    Close-Worker
                    Write-Log 'Atividade detectada. Mineracao encerrada.'
                }
                Restore-Profile
            } elseif (-not $script:worker -and (Get-Date) -ge $retryAt) {
                $ready = Open-Worker
                if ($ready.other_miner) { throw 'Ja existe mineracao manual; aguardando sem alterar os clocks.' }
                if ($cfg.afterburner_mode -eq 'Profile') {
                    $script:profileChanged = $true
                    New-Item -ItemType File -Path $profileMarker -Force | Out-Null
                    Apply-Afterburner $cfg.mining_profile
                } elseif (-not (Get-Process MSIAfterburner -ErrorAction SilentlyContinue)) {
                    Apply-Afterburner 0
                    $script:profileChanged = $true
                }
                # O usuario pode voltar durante a inicializacao do WSL/Afterburner.
                # Mantem o watchdog vivo enquanto os clocks estabilizam.
                for ($i = 0; $i -lt $cfg.settle_seconds; $i++) {
                    Send-Worker 'status' | Out-Null
                    Start-Sleep -Seconds 1
                    if ([PrlWindowsIdle]::Seconds() -lt $cfg.idle_minutes * 60 -or (Test-Path -LiteralPath $stopPath)) { break }
                }
                if ([PrlWindowsIdle]::Seconds() -ge $cfg.idle_minutes * 60 -and -not (Test-Path -LiteralPath $stopPath)) {
                    $answer = Send-Worker 'start'
                    $script:mining = $answer.running
                    Write-Log "Mineracao iniciada, PID Linux $($answer.pid)."
                } else {
                    Close-Worker
                    Restore-Profile
                }
            } elseif ($script:worker) {
                $answer = Send-Worker 'status'
                if (-not $answer.running) { throw 'Minerador encerrou; nova tentativa em 60 segundos.' }
                if (-not (Get-Process MSIAfterburner -ErrorAction SilentlyContinue)) {
                    throw 'Afterburner encerrou; interrompendo a mineracao.'
                }
            }
        } catch {
            Write-Log "Erro: $($_.Exception.Message)"
            Close-Worker
            try { Restore-Profile } catch { Write-Log "Falha ao restaurar perfil: $($_.Exception.Message)" }
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
    try { Restore-Profile } catch { Write-Log "Falha ao restaurar perfil: $($_.Exception.Message)" }
    Write-Log 'Monitor encerrado.'
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
