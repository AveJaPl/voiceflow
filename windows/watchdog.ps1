# voiceflow watchdog - Windows has no systemd Restart=on-failure, so this loop
# stands in for it: started once at logon (through watchdog-hidden.vbs, so no
# console ever exists), it checks every 30s whether the daemon is alive AND
# answering, and restarts it when it is not.
#
# Two distinct failure modes have been seen on real machines. The process dies
# outright - an access violation in _ctypes.pyd, gone from the process list -
# and the process stays alive but wedged: nothing logged, but the IPC port
# stops answering. A plain "is it in the process list" check only catches the
# first, so responsiveness is checked too, through the CLI's own status
# command. One slow reply during a long transcription is normal, not a
# failure, so only $BadCountLimit consecutive bad replies count as wedged -
# that is what tells "busy" apart from "dead".
#
# Deliberately self-contained: it lives beside the data, not inside the
# installed copy, so an update can replace every file of the application
# underneath it without pulling the script out from under a running loop.

$Root = Join-Path $env:LOCALAPPDATA "voiceflow"
$Dest = Join-Path $Root "app"
$Pythonw = Join-Path $Dest ".venv\Scripts\pythonw.exe"
$VoiceflowExe = Join-Path $Dest ".venv\Scripts\voiceflow.exe"
$LogFile = Join-Path $Root "watchdog.log"
$PidFile = Join-Path $Root "watchdog.pid"
$BadCountLimit = 2
$IntervalSeconds = 30
$LogLimitBytes = 256KB

function Write-Log($Message) {
    # An unattended loop writing every 30s must not grow without end. Trimming
    # to the recent half keeps the last few restarts, which is all anyone reads.
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $LogLimitBytes) {
        $Kept = Get-Content $LogFile -Tail 100
        Set-Content -Path $LogFile -Value $Kept -Encoding utf8
    }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# Single instance, guarded by a mutex rather than a pid file. A pid outlives
# nothing: Windows hands the number to an unrelated process soon enough, and a
# watchdog that checks "does pid 10836 exist?" then finds a stranger wearing it
# and politely exits - leaving no watchdog running at all, which is exactly how
# a crashed daemon once stayed down for five minutes. The kernel releases a
# mutex when its owner dies, whatever killed it, and cannot be confused by a
# recycled number. The pid file below is written only so the installer can find
# this loop and stop it.
$Mutex = New-Object System.Threading.Mutex($false, "Local\voiceflow-watchdog")
try {
    $Acquired = $Mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # The previous owner died without releasing it; the kernel just gave it to us.
    $Acquired = $true
}
if (-not $Acquired) {
    Write-Log "Another watchdog is already running; exiting."
    exit 0
}

function Get-VoiceflowProcess {
    <#
      Every process of the installed copy, launcher trampolines included.

      Filtering by image path alone is not enough: uv's launchers re-exec an
      interpreter that lives in uv's own Python directory, so the process
      actually running the daemon has a path outside the install. It is always
      a child of one that does, so the tree is walked from those roots.
    #>
    $All = Get-CimInstance Win32_Process -Filter "Name='python.exe' or Name='pythonw.exe' or Name='voiceflow.exe' or Name='voiceflow-app.exe'"
    $Found = @{}
    $Queue = New-Object System.Collections.Queue
    foreach ($Process in $All) {
        if ($Process.ExecutablePath -and $Process.ExecutablePath.StartsWith($Dest, [StringComparison]::OrdinalIgnoreCase)) {
            $Queue.Enqueue($Process)
        }
    }
    while ($Queue.Count -gt 0) {
        $Process = $Queue.Dequeue()
        if ($Found.ContainsKey($Process.ProcessId)) { continue }
        $Found[$Process.ProcessId] = $Process
        foreach ($Child in ($All | Where-Object { $_.ParentProcessId -eq $Process.ProcessId })) {
            $Queue.Enqueue($Child)
        }
    }
    $Found.Values
}

function Get-Daemon {
    Get-VoiceflowProcess | Where-Object { $_.CommandLine -match '-m\s+voiceflow\s+daemon' }
}

function Start-Daemon($Reason) {
    Write-Log $Reason
    try {
        Start-Process -FilePath $Pythonw -ArgumentList "-m voiceflow daemon" -WorkingDirectory $Dest -WindowStyle Hidden
    } catch {
        Write-Log "Failed to start daemon: $_"
    }
}

try {
    $PID | Out-File -FilePath $PidFile -Encoding ascii -Force
    Write-Log "Watchdog started (pid $PID)."
    $BadCount = 0

    while ($true) {
        $Daemon = Get-Daemon
        if (-not $Daemon) {
            $BadCount = 0
            Start-Daemon "Daemon not running; starting it."
        } else {
            $Reply = & $VoiceflowExe status 2>&1 | Out-String
            if ($Reply -match "nie odpowiada|not responding|timed out") {
                $BadCount++
                Write-Log "Daemon process is alive but unresponsive ($BadCount/$BadCountLimit)."
                if ($BadCount -ge $BadCountLimit) {
                    foreach ($Process in (Get-VoiceflowProcess)) {
                        try { Stop-Process -Id $Process.ProcessId -Force -ErrorAction Stop } catch {}
                    }
                    $BadCount = 0
                    Start-Daemon "Killed wedged daemon; restarting it."
                }
            } else {
                $BadCount = 0
            }
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
}
