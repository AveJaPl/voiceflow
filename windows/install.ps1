# voiceflow installer for Windows - no git required.
#
#   irm https://raw.githubusercontent.com/AveJaPl/voiceflow/main/windows/install.ps1 | iex
#
# Installs into %LOCALAPPDATA%\voiceflow\app, sets up uv + Python environment,
# creates a Start Menu shortcut and an autostart entry. Re-running updates.
#
# Only the bootstrap lives here: stop the running copy, fetch the code, and hand
# over to windows\finish-install.ps1 *inside the fetched tree*. This file is
# always read from main while the tree it fetches is a release, and the two can
# be weeks apart - so nothing here may assume anything about that tree beyond
# the one file it hands over to. (Reaching into it for common.ps1 is how every
# install broke between 17 August and this fix: main had the file, the release
# did not.)
#
# Installs the newest source release (tagged v0.5.0 and the like; the mac-v*
# tags are the macOS build). VOICEFLOW_REF names a branch or tag to install
# instead:
#   $env:VOICEFLOW_REF = "main"; irm https://raw.githubusercontent.com/AveJaPl/voiceflow/main/windows/install.ps1 | iex
$ErrorActionPreference = "Stop"

$Repo = "AveJaPl/voiceflow"
$Root = Join-Path $env:LOCALAPPDATA "voiceflow"
$Dest = Join-Path $Root "app"
# The one thing this bootstrap needs from the tree it downloads.
$Finish = "windows/finish-install.ps1"

# An update must not fight the running copy for its own files: a live daemon
# holds .venv\Scripts\python.exe open and the extraction fails half-way.
# Inline rather than Stop-Voiceflow from the installed copy's common.ps1: that
# copy may predate the file, and dot-sourcing a script answers to the execution
# policy while this bootstrap, piped through iex, does not.
Write-Host "==> Stopping a running voiceflow (if any)" -ForegroundColor Cyan
$Existing = Join-Path $Dest ".venv\Scripts\voiceflow.exe"
if (Test-Path $Existing) {
    try { & $Existing quit 2>$null | Out-Null } catch {}
}
Get-Process -Name "pythonw", "python" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Dest, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object {
        try { $_.Kill(); [void]$_.WaitForExit(5000) } catch {}
    }

Write-Host "==> Downloading voiceflow" -ForegroundColor Cyan
if ($env:VOICEFLOW_REF) {
    $Ref = $env:VOICEFLOW_REF
} else {
    # Releases are per platform: macOS gets a packaged build tagged mac-v0.6.0,
    # everyone else runs the source release tagged v0.5.0. /latest returns
    # whichever was published last, so the list is asked and filtered - the way
    # the daemon's own update check does it (src/voiceflow/updates.py).
    try {
        # Parenthesised: piped straight out of Invoke-RestMethod, Windows PowerShell
        # hands the JSON array down as one object and nothing matches.
        $Ref = (Invoke-RestMethod "https://api.github.com/repos/$Repo/releases?per_page=100") |
            Where-Object { -not $_.prerelease -and $_.tag_name -match "^v?\d" } |
            Sort-Object {
                $Version = ($_.tag_name -replace "^v", "") -replace "[^\d.].*$", ""
                if ($Version -notmatch "\.") { $Version += ".0" }
                [version]$Version
            } -Descending |
            Select-Object -First 1 -ExpandProperty tag_name
        if (-not $Ref) { $Ref = "main" }   # no source release yet
    } catch { $Ref = "main" }   # the API is rate-limited or unreachable
    # A release cut before finish-install.ps1 existed cannot be installed by this
    # bootstrap. main can: it is where the bootstrap itself comes from, so the
    # two agree by construction.
    if ($Ref -ne "main") {
        try { Invoke-WebRequest -Method Head -UseBasicParsing "https://raw.githubusercontent.com/$Repo/$Ref/$Finish" | Out-Null }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw }
            Write-Host "    release $Ref predates this installer, installing main instead" -ForegroundColor DarkGray
            $Ref = "main"
        }
    }
}
Write-Host "    $Ref" -ForegroundColor DarkGray
$Tarball = Join-Path $env:TEMP "voiceflow.tar.gz"
Invoke-WebRequest -UseBasicParsing "https://api.github.com/repos/$Repo/tarball/$Ref" -OutFile $Tarball
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
tar -xzf $Tarball --strip-components=1 -C $Dest
Remove-Item $Tarball

# From here on the tree decides. Environment, launcher repair, shortcuts, model,
# check, daemon - whatever this version needs is written next to its code and
# arrived with it, so a release keeps installing with the steps it shipped with.
# A PowerShell of its own, with the execution policy bypassed: pasting the
# command above into a stock PowerShell must work whatever the machine's policy,
# as it does for iex itself.
$Script = Join-Path $Dest ($Finish -replace "/", "\")
if (-not (Test-Path $Script)) {
    throw "$Ref carries no $Finish - name a newer branch or tag in VOICEFLOW_REF"
}
& powershell -NoProfile -ExecutionPolicy Bypass -File $Script
if ($LASTEXITCODE -ne 0) { throw "voiceflow did not install - see the output above" }
