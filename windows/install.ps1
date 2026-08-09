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

Write-Host "==> Creating launcher, Start Menu entry and autostart" -ForegroundColor Cyan
# Hidden launcher (no console window): wscript runs the daemon invisibly.
$Vbs = Join-Path $env:LOCALAPPDATA "voiceflow\voiceflow-hidden.vbs"
@"
Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = "$Dest"
shell.Run "cmd /c uv run voiceflow daemon", 0, False
"@ | Set-Content -Path $Vbs -Encoding ascii

# Start Menu shortcut with the application icon.
$Ico = Join-Path $Dest "windows\voiceflow.ico"
$StartMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "voiceflow.lnk"
$Startup = Join-Path ([Environment]::GetFolderPath("Startup")) "voiceflow.lnk"
$Shell = New-Object -ComObject WScript.Shell
foreach ($LinkPath in @($StartMenu, $Startup)) {
    $Link = $Shell.CreateShortcut($LinkPath)
    $Link.TargetPath = "wscript.exe"
    $Link.Arguments = "`"$Vbs`""
    $Link.WorkingDirectory = $Dest
    if (Test-Path $Ico) { $Link.IconLocation = $Ico }
    $Link.Description = "voiceflow - dyktowanie glosowe (Ctrl+Shift+Space)"
    $Link.Save()
}

Write-Host ""
Write-Host "Done. Find *voiceflow* in the Start Menu (it also autostarts on login)." -ForegroundColor Green
Write-Host "First start downloads the speech model (~1.6 GB)."
Write-Host "Hotkey: Ctrl+Shift+Space (change in %APPDATA%\voiceflow\config.yaml)."
