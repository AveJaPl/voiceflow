# Shared by install.ps1 (downloads a release) and install-local.ps1 (installs
# this working copy). Both end the same way: a venv that starts without a
# console window, and the two shortcuts that use it.

function Stop-Voiceflow {
    <#
      An update must not fight the running copy for its own files: a live daemon
      holds .venv\Scripts\python.exe open and the extraction fails half-way.
    #>
    param([Parameter(Mandatory)][string]$Dest)

    $Existing = Join-Path $Dest ".venv\Scripts\voiceflow.exe"
    if (Test-Path $Existing) {
        try { & $Existing quit 2>$null | Out-Null } catch {}
    }
    Get-Process -Name "pythonw", "python" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Dest, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            try { $_.Kill(); [void]$_.WaitForExit(5000) } catch {}
        }
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
        Startup    -> the daemon, headless, through pythonw.exe so no console
                      exists to flash or to hide.
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

    $Startup = Join-Path ([Environment]::GetFolderPath("Startup")) "voiceflow.lnk"
    $Link = $Shell.CreateShortcut($Startup)
    $Link.TargetPath = $Pythonw
    $Link.Arguments = "-m voiceflow daemon"
    $Link.WorkingDirectory = $Dest
    if (Test-Path $Ico) { $Link.IconLocation = $Ico }
    $Link.Description = "voiceflow - dyktowanie glosowe (Ctrl+Shift+Space)"
    $Link.Save()

    # Superseded by the direct pythonw launch; leaving it behind would keep an
    # older, uv-dependent path alive in anyone's Startup folder.
    $LegacyVbs = Join-Path (Split-Path -Parent $Dest) "voiceflow-hidden.vbs"
    if (Test-Path $LegacyVbs) { Remove-Item $LegacyVbs -Force }
}
