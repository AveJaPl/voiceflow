# Install *this* working copy as the installed voiceflow, without going through
# GitHub.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\install-local.ps1
#
# The Start Menu shortcut and the autostart entry point at
# %LOCALAPPDATA%\voiceflow\app, which install.ps1 fills from a release. While
# the window and the daemon are being worked on, that copy is a release behind
# and clicking the icon opens yesterday's application. This makes the installed
# copy the checkout, keeps the venv and the downloaded model in place, and
# leaves everything else exactly as the network installer left it.
param(
    [string]$Source = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = "Stop"

$Dest = Join-Path (Join-Path $env:LOCALAPPDATA "voiceflow") "app"
if (-not (Test-Path (Join-Path $Source "pyproject.toml"))) {
    throw "$Source nie wyglada na katalog voiceflow (brak pyproject.toml)"
}
. (Join-Path $PSScriptRoot "common.ps1")

Write-Host "==> Stopping a running voiceflow (if any)" -ForegroundColor Cyan
Stop-Voiceflow -Dest $Dest

Write-Host "==> Copying $Source -> $Dest" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
# /MIR so files deleted in the checkout disappear from the install too, with the
# environment, the git database and build leftovers excluded - .venv especially,
# which holds the 1.6 GB model's environment and must survive.
$Excluded = @(".git", ".venv", "__pycache__", ".pytest_cache", ".ruff_cache", "node_modules")
robocopy $Source $Dest /MIR /XD $Excluded /NFL /NDL /NJH /NJS /NP | Out-Null
# robocopy speaks in bit flags: under 8 means it copied (or had nothing to do).
if ($LASTEXITCODE -ge 8) { throw "robocopy zakonczyl sie kodem $LASTEXITCODE" }
$global:LASTEXITCODE = 0

Write-Host "==> Syncing the Python environment (uv)" -ForegroundColor Cyan
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
}
Push-Location $Dest
uv sync
Pop-Location

Write-Host "==> Making the windowless launcher windowless" -ForegroundColor Cyan
Repair-VenvLauncher -Dest $Dest

Write-Host "==> Creating Start Menu entry and autostart" -ForegroundColor Cyan
Set-VoiceflowShortcuts -Dest $Dest

Write-Host "==> Starting the daemon" -ForegroundColor Cyan
$Pythonw = Join-Path $Dest ".venv\Scripts\pythonw.exe"
Start-Process -FilePath $Pythonw -ArgumentList "-m voiceflow daemon" -WorkingDirectory $Dest

Write-Host ""
Write-Host "Done. Start Menu -> voiceflow opens this checkout's window." -ForegroundColor Green
