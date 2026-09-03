# The second half of every Windows install: makes the voiceflow tree this file
# sits in a working, autostarting installation.
#
# Both installers end here - install.ps1 after downloading a release,
# install-local.ps1 after copying a checkout - so the steps exist once. It is a
# file in the tree and not a piece of the bootstrap on purpose: install.ps1 is
# always read from main, the tree it downloads is a release, and the two can be
# weeks apart. What it takes to make *this* version run is decided next to this
# version's code, and travels with it.
$ErrorActionPreference = "Stop"

$Dest = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "common.ps1")

Write-Host "==> Setting up Python environment (uv)" -ForegroundColor Cyan
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    # A uv installed by an earlier run lives here, but is not on this shell's
    # PATH until the next sign-in.
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        irm https://astral.sh/uv/install.ps1 | iex
    }
}
Push-Location $Dest
uv sync
Pop-Location
if ($LASTEXITCODE -ne 0) { throw "uv sync failed - see the output above" }

# Everything below runs the venv directly. Resolving uv at *launch* time was
# fragile: the shortcut inherits whatever PATH the shell had at login, and a
# freshly installed uv is not on it until the next sign-in.
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
