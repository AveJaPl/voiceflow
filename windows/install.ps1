# voiceflow installer for Windows - no git required.
#
#   irm https://raw.githubusercontent.com/AveJaPl/voiceflow/main/windows/install.ps1 | iex
#
# Installs into %LOCALAPPDATA%\voiceflow\app, sets up uv + Python environment,
# creates a Start Menu shortcut and an autostart entry. Re-running updates.
$ErrorActionPreference = "Stop"

$Root = Join-Path $env:LOCALAPPDATA "voiceflow"
$Dest = Join-Path $Root "app"

Write-Host "==> Stopping a running voiceflow (if any)" -ForegroundColor Cyan
$Installed = Join-Path $Dest "windows\common.ps1"
if (Test-Path $Installed) {
    . $Installed
    Stop-Voiceflow -Dest $Dest
} else {
    # First install: nothing is running, and the helpers arrive with the code.
    Get-Process -Name "pythonw", "python" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Dest, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            try { $_.Kill(); $_.WaitForExit(5000) } catch {}
        }
}

Write-Host "==> Downloading voiceflow" -ForegroundColor Cyan
$Tarball = Join-Path $env:TEMP "voiceflow.tar.gz"
try {
    $Release = Invoke-RestMethod "https://api.github.com/repos/AveJaPl/voiceflow/releases/latest"
    $Url = $Release.tarball_url
} catch { $Url = "https://api.github.com/repos/AveJaPl/voiceflow/tarball/main" }
Invoke-WebRequest $Url -OutFile $Tarball
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
tar -xzf $Tarball --strip-components=1 -C $Dest
Remove-Item $Tarball

Write-Host "==> Setting up Python environment (uv)" -ForegroundColor Cyan
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    irm https://astral.sh/uv/install.ps1 | iex
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
}
Push-Location $Dest
uv sync
Pop-Location

# Everything below runs the venv directly. Resolving uv at *launch* time was
# fragile: the shortcut inherits whatever PATH the shell had at login, and a
# freshly installed uv is not on it until the next sign-in.
. (Join-Path $Dest "windows\common.ps1")
$Pythonw = Join-Path $Dest ".venv\Scripts\pythonw.exe"
if (-not (Test-Path $Pythonw)) { throw "uv sync did not produce $Pythonw" }

Write-Host "==> Making the windowless launcher windowless" -ForegroundColor Cyan
Repair-VenvLauncher -Dest $Dest

Write-Host "==> Creating Start Menu entry and autostart" -ForegroundColor Cyan
Set-VoiceflowShortcuts -Dest $Dest

Write-Host "==> Downloading the speech model (~1.6 GB) - progress below" -ForegroundColor Cyan
Push-Location $Dest
uv run voiceflow download-model
Pop-Location

Write-Host "==> Verifying the installation" -ForegroundColor Cyan
$Voiceflow = Join-Path $Dest ".venv\Scripts\voiceflow.exe"
& $Voiceflow models | Out-Null
if ($LASTEXITCODE -ne 0) { throw "voiceflow is installed but does not run - see the output above" }
Write-Host "    command line OK" -ForegroundColor DarkGray

# Start it now, so the hotkey works without waiting for the next sign-in.
Start-Process -FilePath $Pythonw -ArgumentList "-m voiceflow daemon" -WorkingDirectory $Dest
Write-Host "    daemon started" -ForegroundColor DarkGray

Write-Host ""
Write-Host "Done. voiceflow is running now and autostarts on login." -ForegroundColor Green
Write-Host "Press Ctrl+Shift+Space, speak, press it again - the text lands in the focused window."
Write-Host "Open *voiceflow* in the Start Menu for settings, history and statistics."
Write-Host "Check it any time:  %LOCALAPPDATA%\voiceflow\app\.venv\Scripts\voiceflow.exe status"
Write-Host "Hotkey and settings: %APPDATA%\voiceflow\config.yaml"
Write-Host "Log:                 %LOCALAPPDATA%\voiceflow\daemon.log"
