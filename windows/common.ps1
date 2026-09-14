# Shared by install.ps1 (downloads a release) and install-local.ps1 (installs
# this working copy). Both end the same way: a venv that starts without a
# console window, and the two shortcuts that use it.

function Get-VoiceflowProcess {
    <#
      Every process of the installed copy, launcher trampolines included.

      Filtering by image path alone misses the important one: uv's launchers
      re-exec an interpreter that lives in uv's own Python directory, so the
      process actually running the daemon has a path outside the install and
      survived every "stop the running copy" this function used to do - holding
      files open through the update that was meant to replace them. It is always
      a child of a process that does live here, so the tree is walked from those
      roots instead. watchdog.ps1 carries its own copy of this on purpose: it
      must keep working while these very files are being replaced.
    #>
    param([Parameter(Mandatory)][string]$Dest)

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

function Stop-Watchdog {
    <#
      The watchdog goes first and stays gone for the whole update: its whole
      purpose is to start a daemon whenever it does not see one, which during an
      installation means starting the old copy on top of the new one, out of
      files that are being replaced.
    #>
    param([Parameter(Mandatory)][string]$Root)

    $PidFile = Join-Path $Root "watchdog.pid"
    if (-not (Test-Path $PidFile)) { return }
    $WatchdogPid = Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    # The file may name a number Windows has since given to somebody else, so
    # only a process actually running our own script is fair game.
    if ($WatchdogPid) {
        $Process = Get-CimInstance Win32_Process -Filter "ProcessId=$WatchdogPid" -ErrorAction SilentlyContinue
        if ($Process -and $Process.CommandLine -match "watchdog\.ps1") {
            try { Stop-Process -Id $Process.ProcessId -Force -ErrorAction Stop } catch {}
        }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

function Stop-Voiceflow {
    <#
      An update must not fight the running copy for its own files: a live daemon
      holds .venv\Scripts\python.exe open and the extraction fails half-way.
    #>
    param([Parameter(Mandatory)][string]$Dest)

    Stop-Watchdog -Root (Split-Path -Parent $Dest)
    $Existing = Join-Path $Dest ".venv\Scripts\voiceflow.exe"
    if (Test-Path $Existing) {
        try { & $Existing quit 2>$null | Out-Null } catch {}
        Start-Sleep -Milliseconds 500
    }
    foreach ($Process in (Get-VoiceflowProcess -Dest $Dest)) {
        try {
            $Handle = Get-Process -Id $Process.ProcessId -ErrorAction Stop
            $Handle.Kill()
            [void]$Handle.WaitForExit(5000)
        } catch {}
    }
}

function Install-Watchdog {
    <#
      The watchdog lives beside the data, not in the installed copy, so that an
      update can replace every file of the application without pulling the
      script out from under the loop that is running it.
    #>
    param([Parameter(Mandatory)][string]$Dest, [Parameter(Mandatory)][string]$Root)

    foreach ($Name in @("watchdog.ps1", "watchdog-hidden.vbs")) {
        Copy-Item (Join-Path $Dest "windows\$Name") (Join-Path $Root $Name) -Force
    }
}

function Start-Watchdog {
    <#
      Through the .vbs, so this start is the same windowless one the Startup
      shortcut performs at every logon.
    #>
    param([Parameter(Mandatory)][string]$Root)

    $Vbs = Join-Path $Root "watchdog-hidden.vbs"
    Start-Process -FilePath (Join-Path $env:SystemRoot "System32\wscript.exe") -ArgumentList "`"$Vbs`"" -WorkingDirectory $Root
}

function Repair-VenvLauncher {
    <#
      Make .venv\Scripts\pythonw.exe a real interpreter again.

      uv builds it as a trampoline that re-launches the *console* interpreter of
      the base installation. A console program whose parent has no console gets
      a new console window of its own - so every windowless start (the autostart
      daemon, the Start Menu window, the daemon the window launches for itself)
      opened a black window full of log lines in front of the user's work.

      The fix is what python -m venv does on Windows anyway: copy the real
      pythonw.exe over, with the DLLs that sit beside it, and let pyvenv.cfg
      point at the base installation for the standard library. python.exe is
      deliberately left as it is - the command line wants its console.
    #>
    param([Parameter(Mandatory)][string]$Dest)

    $Scripts = Join-Path $Dest ".venv\Scripts"
    $Config = Join-Path $Dest ".venv\pyvenv.cfg"
    if (-not (Test-Path $Config)) { return }

    $HomeLine = Get-Content $Config | Where-Object { $_ -match '^\s*home\s*=' } | Select-Object -First 1
    if (-not $HomeLine) { return }
    $BaseDir = ($HomeLine -replace '^\s*home\s*=\s*', '').Trim()
    $Source = Join-Path $BaseDir "pythonw.exe"
    $Target = Join-Path $Scripts "pythonw.exe"
    if (-not (Test-Path $Source) -or -not (Test-Path $Target)) { return }
    # Same size means the copy already happened; a trampoline is a fraction of
    # the real interpreter, never the same file.
    if ((Get-Item $Source).Length -eq (Get-Item $Target).Length) { return }

    $Backup = Join-Path $Scripts "pythonw-uv.exe"
    Copy-Item $Target $Backup -Force
    foreach ($Dll in (Get-ChildItem $BaseDir -Filter "*.dll" |
            Where-Object { $_.Name -like "python*.dll" -or $_.Name -like "vcruntime*.dll" })) {
        $Beside = Join-Path $Scripts $Dll.Name
        if (-not (Test-Path $Beside)) { Copy-Item $Dll.FullName $Beside -Force }
    }
    Copy-Item $Source $Target -Force

    # Prove it before trusting it: the copy must find the venv's packages, or
    # the trampoline goes back and the console window is the lesser problem.
    # Quoted here, because Start-Process joins the list with spaces and an
    # unquoted "import voiceflow" would reach python as two arguments.
    $Check = Start-Process -FilePath $Target -ArgumentList "-c", '"import voiceflow"' -PassThru -Wait
    if ($Check.ExitCode -ne 0) {
        Copy-Item $Backup $Target -Force
        Write-Host "    pythonw.exe left as uv built it (weryfikacja nie przeszla)" -ForegroundColor DarkYellow
        return
    }
    Remove-Item $Backup -Force -ErrorAction SilentlyContinue
    Write-Host "    pythonw.exe uruchamia sie bez konsoli" -ForegroundColor DarkGray
}

function Set-VoiceflowShortcuts {
    <#
      Two different things, deliberately:
        Start Menu -> the desktop window, because that is what clicking an app
                      icon must do. Pointing it at the daemon meant clicking it
                      did nothing at all once the daemon was already running.
        Startup    -> the watchdog, which starts the daemon and keeps starting
                      it: the daemon can die or wedge, and a dictation shortcut
                      that has silently stopped working is worse than none.
                      Windows has no systemd Restart=on-failure to ask for.
    #>
    param([Parameter(Mandatory)][string]$Dest)

    $Pythonw = Join-Path $Dest ".venv\Scripts\pythonw.exe"
    if (-not (Test-Path $Pythonw)) { throw "brak $Pythonw - uv sync nie zbudowal srodowiska" }
    $Ico = Join-Path $Dest "windows\voiceflow.ico"
    $Shell = New-Object -ComObject WScript.Shell

    $StartMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "voiceflow.lnk"
    $Link = $Shell.CreateShortcut($StartMenu)
    $Link.TargetPath = Join-Path $Dest ".venv\Scripts\voiceflow-app.exe"
    $Link.WorkingDirectory = $Dest
    if (Test-Path $Ico) { $Link.IconLocation = $Ico }
    $Link.Description = "voiceflow - ustawienia, historia i statystyki dyktowania"
    $Link.Save()

    $Root = Split-Path -Parent $Dest
    $Startup = Join-Path ([Environment]::GetFolderPath("Startup")) "voiceflow.lnk"
    $Link = $Shell.CreateShortcut($Startup)
    # wscript, not powershell: the .vbs is what makes the loop start with no
    # console window at all, rather than one that flashes and is then hidden.
    $Link.TargetPath = Join-Path $env:SystemRoot "System32\wscript.exe"
    $Link.Arguments = "`"$(Join-Path $Root 'watchdog-hidden.vbs')`""
    $Link.WorkingDirectory = $Root
    if (Test-Path $Ico) { $Link.IconLocation = $Ico }
    $Link.Description = "voiceflow - dyktowanie glosowe (Ctrl+Shift+Space)"
    $Link.Save()

    # Superseded by the watchdog; leaving it behind would keep an older,
    # uv-dependent path alive in anyone's Startup folder.
    $LegacyVbs = Join-Path $Root "voiceflow-hidden.vbs"
    if (Test-Path $LegacyVbs) { Remove-Item $LegacyVbs -Force }
}
