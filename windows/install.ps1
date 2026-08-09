# voiceflow installer for Windows - no git required.
#
#   irm https://raw.githubusercontent.com/AveJaPl/voiceflow/main/windows/install.ps1 | iex
#
# Installs into %LOCALAPPDATA%\voiceflow\app, sets up uv + Python environment,
# creates a Start Menu shortcut and an autostart entry. Re-running updates.
$ErrorActionPreference = "Stop"

$Dest = Join-Path $env:LOCALAPPDATA "voiceflow\app"
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

Write-Host "==> Creating launcher and autostart" -ForegroundColor Cyan
$Launcher = Join-Path $env:LOCALAPPDATA "voiceflow\voiceflow.bat"
"@echo off`ncd /d `"$Dest`"`nstart `"voiceflow`" /min cmd /c `"uv run voiceflow daemon`"" |
    Set-Content -Path $Launcher -Encoding ascii
$Startup = [Environment]::GetFolderPath("Startup")
Copy-Item $Launcher (Join-Path $Startup "voiceflow.bat") -Force

Write-Host ""
Write-Host "Done. Start now with: $Launcher" -ForegroundColor Green
Write-Host "First start downloads the speech model (~1.6 GB)."
Write-Host "Hotkey: Ctrl+Shift+Space (change in %APPDATA%\voiceflow\config.yaml)."
