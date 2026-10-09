# Skybound auto-sync for Windows.
# Keeps C:\Users\<you>\Documents\skybound identical to the latest Skybound
# code on GitHub, so `rojo serve` pushes every update into Studio live.
# Start it once and leave the window open. Ctrl+C stops it.
#
# What it touches: only the project folder below. Before replacing `src` it
# copies your current one to `src.backup-<time>` (first run) and keeps the
# last version in `src.previous`.

$Project  = Join-Path $env:USERPROFILE 'Documents\skybound'
$Repo     = 'mikail01/skybound'
$Branch   = 'claude/roblox-studio-connection-isznfe'
$Rojo     = Join-Path $env:USERPROFILE 'Downloads\rojo-7.4.4-windows-x86_64\rojo.exe'
$Interval = 90   # seconds between checks (GitHub allows 60 anonymous checks/hour)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say($text, $color = 'Gray') {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $text) -ForegroundColor $color
}

function Ensure-Rojo {
    $listening = Get-NetTCPConnection -LocalPort 34872 -State Listen -ErrorAction SilentlyContinue
    if ($listening) { return }
    if (Test-Path $Rojo) {
        Say 'Rojo is not running - starting "rojo serve" in a new window.' 'Yellow'
        Start-Process -FilePath $Rojo -ArgumentList 'serve' -WorkingDirectory $Project
    } else {
        Say "Rojo is not running and rojo.exe was not found at $Rojo. Start it yourself with: rojo serve" 'Yellow'
    }
}

function Sync-Commit($sha) {
    $zip = Join-Path $env:TEMP "skybound-$sha.zip"
    $tmp = Join-Path $env:TEMP "skybound-$sha"
    Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$Repo/zip/$sha" -OutFile $zip
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $source = Get-ChildItem $tmp -Directory | Select-Object -First 1
    if (-not (Test-Path (Join-Path $source.FullName 'default.project.json'))) {
        throw 'Downloaded archive has no default.project.json'
    }

    New-Item -ItemType Directory -Force -Path $Project | Out-Null
    $src = Join-Path $Project 'src'
    if (Test-Path $src) {
        $marker = Join-Path $Project '.skybound-backup-done'
        if (-not (Test-Path $marker)) {
            $backup = Join-Path $Project ("src.backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Copy-Item $src $backup -Recurse
            New-Item -ItemType File -Path $marker | Out-Null
            Say "Backed up your original src to $backup"
        }
        $previous = Join-Path $Project 'src.previous'
        if (Test-Path $previous) { Remove-Item $previous -Recurse -Force }
        Copy-Item $src $previous -Recurse
    }

    # Mirror src exactly (robocopy exit codes below 8 mean success).
    robocopy (Join-Path $source.FullName 'src') $src /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with code $LASTEXITCODE" }
    foreach ($file in 'default.project.json', 'README.md', 'selene.toml', 'stylua.toml', 'rokit.toml', 'wally.toml') {
        $from = Join-Path $source.FullName $file
        if (Test-Path $from) { Copy-Item $from (Join-Path $Project $file) -Force }
    }
    $toolsFrom = Join-Path $source.FullName 'tools'
    if (Test-Path $toolsFrom) {
        robocopy $toolsFrom (Join-Path $Project 'tools') /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    }

    Set-Content -Path (Join-Path $Project '.skybound-sync') -Value $sha
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Say "Skybound auto-sync -> $Project" 'Cyan'
Say "Watching github.com/$Repo ($Branch). Leave this window open." 'Cyan'
$stateFile = Join-Path $Project '.skybound-sync'
$current = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { '' }

while ($true) {
    try {
        $commit = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/commits/$Branch" -Headers @{ 'User-Agent' = 'skybound-autosync' }
        $sha = $commit.sha
        if ($sha -and $sha -ne $current) {
            $title = ($commit.commit.message -split "`n")[0]
            Say "New version $($sha.Substring(0, 7)): $title" 'Green'
            Sync-Commit $sha
            $current = $sha
            Say 'Project updated. Rojo will push the change into Studio; press Play again to test.' 'Green'
        }
        Ensure-Rojo
    } catch {
        Say "Check failed (will retry): $($_.Exception.Message)" 'Yellow'
    }
    Start-Sleep -Seconds $Interval
}
