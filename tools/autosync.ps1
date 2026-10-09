<#
Skybound auto-sync for Windows (hardened).

Keeps the Skybound files in your local Rojo project up to date with the code
on GitHub, so `rojo serve` pushes each update into Studio.

SAFETY RULES THIS SCRIPT FOLLOWS
  * It only writes MANAGED files (listed below). Anything else in your project
    folder is never modified or deleted.
  * Every download is unpacked and validated in a temporary folder first. Your
    project is not touched unless the whole download passes validation.
  * Updates are journaled. If an update fails part-way, it is rolled back
    immediately; if the window is closed mid-update, the next run rolls it
    back automatically before doing anything else.
  * Your original files are copied once to .skybound-sync\original\ and that
    copy is never overwritten or deleted by this script.
  * A managed file you edited yourself is never overwritten: the update is
    refused and the conflict is reported.
  * It never runs any PowerShell it downloads. A newer copy of this script may
    be saved to tools\autosync.ps1 in the project, but only you can run it.
  * The first sync shows a dry-run summary and only applies after you type YES.

MANAGED FILES (the only paths it may create, replace or remove)
  src\**                 every file in the upstream src folder
  tools\**               every file in the upstream tools folder
  default.project.json, README.md, selene.toml, stylua.toml, rokit.toml,
  wally.toml
  ...but only files that came from upstream. A managed file is only removed
  if a previous sync wrote it and you have not changed it since.

STATE (all inside .skybound-sync\ in the project)
  state.json       last synced commit
  manifest.json    SHA-256 of every file this script wrote
  original\        permanent backup of your files before the first sync
  journal\         in-progress update (exists only while applying)
  sync.log         log of every sync

USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File autosync.ps1 [options]
    -DryRun          show what would change, change nothing, then exit
    -Pin <sha>       sync exactly this commit (and stop following the branch)
    -Once            check once, then exit
    -NoRojo          do not start rojo serve
    -Project <path>  project folder (default: Documents\skybound)
#>

[CmdletBinding()]
param(
    [string]$Project = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Documents\skybound'),
    [string]$Repo = 'mikail01/skybound',
    [string]$Branch = 'claude/roblox-studio-connection-isznfe',
    [string]$Pin = '',
    [int]$Interval = 90,
    [switch]$DryRun,
    [switch]$Once,
    [switch]$NoRojo,
    [string]$Rojo = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\rojo-7.4.4-windows-x86_64\rojo.exe'),
    # Overridable only so the test suite can use a local fake GitHub.
    [string]$ApiBase = 'https://api.github.com',
    [string]$DownloadBase = 'https://codeload.github.com'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$ScriptVersion = 2
$ManagedRootFiles = @('default.project.json', 'README.md', 'selene.toml', 'stylua.toml', 'rokit.toml', 'wally.toml')
$ManagedDirs = @('src', 'tools')
$RequiredFiles = @('default.project.json', 'src/server/init.server.luau', 'src/client/init.client.luau')
$MinLuauFiles = 10

$StateDir = Join-Path $Project '.skybound-sync'
$StateFile = Join-Path $StateDir 'state.json'
$ManifestFile = Join-Path $StateDir 'manifest.json'
$OriginalDir = Join-Path $StateDir 'original'
$JournalDir = Join-Path $StateDir 'journal'
$LogFile = Join-Path $StateDir 'sync.log'

# Test-only fault injection: fail (or hard-exit) after N file writes.
$FaultAfter = 0
if ($env:SKYBOUND_SYNC_FAULT_AFTER) { $FaultAfter = [int]$env:SKYBOUND_SYNC_FAULT_AFTER }
$FaultMode = $env:SKYBOUND_SYNC_FAULT_MODE   # 'throw' or 'exit'
$script:WriteCount = 0

# --- helpers --------------------------------------------------------------------

function Say([string]$text, [string]$color = 'Gray') {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $text
    Write-Host $line -ForegroundColor $color
    if (Test-Path $StateDir) { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue }
}

function Rel([string]$root, [string]$full) {
    $r = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    $f = [IO.Path]::GetFullPath($full)
    return $f.Substring($r.Length + 1).Replace('\', '/')
}

function Local-Path([string]$root, [string]$rel) {
    return Join-Path $root ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
}

function Hash([string]$path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}

function Read-JsonTable([string]$path) {
    $table = @{}
    if (Test-Path -LiteralPath $path) {
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj) { foreach ($p in $obj.PSObject.Properties) { $table[$p.Name] = $p.Value } }
    }
    return $table
}

function Write-JsonAtomic([string]$path, $value) {
    $tmp = "$path.tmp"
    ($value | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tmp -Encoding UTF8
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}

function Is-Managed([string]$rel) {
    if ($ManagedRootFiles -contains $rel) { return $true }
    foreach ($d in $ManagedDirs) { if ($rel.StartsWith("$d/")) { return $true } }
    return $false
}

function Fault-Point {
    $script:WriteCount++
    if ($FaultAfter -gt 0 -and $script:WriteCount -ge $FaultAfter) {
        if ($FaultMode -eq 'exit') { [Environment]::Exit(99) }
        throw "Injected test fault after $($script:WriteCount) writes"
    }
}

# Replace one file via a temp file + rename, so a file is never half-written.
function Put-File([string]$from, [string]$to) {
    $dir = Split-Path -Parent $to
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$to.skybound-tmp"
    Copy-Item -LiteralPath $from -Destination $tmp -Force
    Fault-Point
    if (Test-Path -LiteralPath $to) { [IO.File]::Replace($tmp, $to, [NullString]::Value) } else { [IO.File]::Move($tmp, $to) }
}

function Invoke-Api([string]$path) {
    return Invoke-RestMethod -UseBasicParsing -Uri "$ApiBase/repos/$Repo/$path" -Headers @{ 'User-Agent' = 'skybound-autosync'; 'Accept' = 'application/vnd.github+json' }
}

# --- download + validation (temp folder only) --------------------------------------

function Get-Snapshot([string]$sha) {
    $work = Join-Path ([IO.Path]::GetTempPath()) ("skybound-sync-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $zip = Join-Path $work 'download.zip'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$DownloadBase/$Repo/zip/$sha" -OutFile $zip
    } catch {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        throw "Download failed for commit $($sha.Substring(0, 7)): $($_.Exception.Message)"
    }
    $zipHash = Hash $zip
    $extract = Join-Path $work 'x'
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    } catch {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        throw "Downloaded file is not a valid zip archive: $($_.Exception.Message)"
    }
    $tops = @(Get-ChildItem -LiteralPath $extract -Force)
    $repoName = $Repo.Split('/')[1]
    if ($tops.Count -ne 1 -or -not $tops[0].PSIsContainer -or $tops[0].Name -ne "$repoName-$sha") {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        throw "Archive does not contain exactly the folder '$repoName-$sha' (commit mismatch or bad archive)"
    }
    $root = $tops[0].FullName
    $problems = @()
    foreach ($req in $RequiredFiles) {
        $p = Local-Path $root $req
        if (-not (Test-Path -LiteralPath $p)) { $problems += "missing $req" }
        elseif ((Get-Item -LiteralPath $p).Length -eq 0) { $problems += "empty $req" }
    }
    $luau = @(Get-ChildItem -LiteralPath (Local-Path $root 'src') -Recurse -File -Filter '*.luau' -ErrorAction SilentlyContinue)
    if ($luau.Count -lt $MinLuauFiles) { $problems += "src has only $($luau.Count) .luau files (expected at least $MinLuauFiles)" }
    foreach ($f in $luau) { if ($f.Length -eq 0) { $problems += "empty $(Rel $root $f.FullName)" } }
    $projectFile = Local-Path $root 'default.project.json'
    if (Test-Path -LiteralPath $projectFile) {
        try {
            $proj = Get-Content -LiteralPath $projectFile -Raw | ConvertFrom-Json
            $paths = New-Object System.Collections.Generic.List[string]
            $walk = $null
            $walk = {
                param($node)
                foreach ($prop in $node.PSObject.Properties) {
                    if ($prop.Name -eq '$path') { $paths.Add([string]$prop.Value) }
                    elseif ($prop.Value -is [System.Management.Automation.PSCustomObject]) { & $walk $prop.Value }
                }
            }
            & $walk $proj.tree
            if ($paths.Count -eq 0) { $problems += 'default.project.json maps no $path entries' }
            foreach ($mapped in $paths) {
                if (-not (Test-Path -LiteralPath (Local-Path $root $mapped))) { $problems += "project maps missing path '$mapped'" }
            }
        } catch {
            $problems += "default.project.json is not valid JSON: $($_.Exception.Message)"
        }
    }
    if ($problems.Count -gt 0) {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        throw ("Commit $($sha.Substring(0, 7)) failed validation: " + ($problems -join '; '))
    }
    $files = @{}
    foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $rel = Rel $root $f.FullName
        if (Is-Managed $rel) { $files[$rel] = Hash $f.FullName }
    }
    return [pscustomobject]@{ Work = $work; Root = $root; Files = $files; ZipHash = $zipHash; LuauCount = $luau.Count }
}

# --- planning ------------------------------------------------------------------------

function Get-Plan($snapshot, $manifest) {
    $plan = [pscustomobject]@{ Add = @(); Update = @(); Remove = @(); Conflicts = @(); Unknown = @(); Unchanged = 0 }
    foreach ($rel in ($snapshot.Files.Keys | Sort-Object)) {
        $target = Local-Path $Project $rel
        if (-not (Test-Path -LiteralPath $target)) { $plan.Add += $rel; continue }
        $localHash = Hash $target
        if ($localHash -eq $snapshot.Files[$rel]) { $plan.Unchanged++; continue }
        if ($manifest.Count -gt 0 -and $manifest.ContainsKey($rel) -and $manifest[$rel] -ne $localHash) {
            $plan.Conflicts += $rel   # you edited a file the sync wrote
        } else {
            $plan.Update += $rel      # ours, or first sync (backed up first)
        }
    }
    foreach ($rel in ($manifest.Keys | Sort-Object)) {
        if ($snapshot.Files.ContainsKey($rel)) { continue }
        $target = Local-Path $Project $rel
        if (-not (Test-Path -LiteralPath $target)) { continue }
        if ((Hash $target) -eq $manifest[$rel]) { $plan.Remove += $rel } else { $plan.Conflicts += $rel }
    }
    # Files inside managed folders that the sync never wrote: left alone, but
    # reported, because a stray .luau file in src would still run in Studio.
    foreach ($d in $ManagedDirs) {
        $dir = Local-Path $Project $d
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Force) {
            $rel = Rel $Project $f.FullName
            if ($rel.EndsWith('.skybound-tmp')) { continue }
            if (-not $snapshot.Files.ContainsKey($rel) -and -not $manifest.ContainsKey($rel)) { $plan.Unknown += $rel }
        }
    }
    return $plan
}

function Show-Plan($plan, [string]$sha) {
    Say "Plan for commit $sha"
    Say ("  {0} new, {1} replaced, {2} removed, {3} unchanged" -f $plan.Add.Count, $plan.Update.Count, $plan.Remove.Count, $plan.Unchanged)
    foreach ($r in $plan.Add) { Say "  + $r" 'Green' }
    foreach ($r in $plan.Update) { Say "  ~ $r" 'Yellow' }
    foreach ($r in $plan.Remove) { Say "  - $r" 'Red' }
    foreach ($r in $plan.Conflicts) { Say "  ! $r  (you changed this file; it will NOT be overwritten)" 'Magenta' }
    foreach ($r in $plan.Unknown) { Say "  ? $r  (not from Skybound; left untouched)" 'DarkGray' }
}

# --- original backup -------------------------------------------------------------------

function Ensure-OriginalBackup($snapshot) {
    if (Test-Path -LiteralPath $OriginalDir) { return }   # never overwrite
    $tmp = "$OriginalDir.partial"
    if (Test-Path -LiteralPath $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $count = 0
    $candidates = @{}
    foreach ($rel in $snapshot.Files.Keys) { $candidates[$rel] = $true }
    foreach ($d in $ManagedDirs) {
        $dir = Local-Path $Project $d
        if (Test-Path -LiteralPath $dir) {
            foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Force) { $candidates[(Rel $Project $f.FullName)] = $true }
        }
    }
    foreach ($rel in $ManagedRootFiles) { $candidates[$rel] = $true }
    foreach ($rel in $candidates.Keys) {
        $src = Local-Path $Project $rel
        if (Test-Path -LiteralPath $src) {
            $dst = Local-Path $tmp $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst
            $count++
        }
    }
    Set-Content -LiteralPath (Join-Path $tmp 'README.txt') -Value "Your Skybound files as they were before the first auto-sync ($(Get-Date -Format s)). The sync script never changes this folder."
    [IO.Directory]::Move($tmp, $OriginalDir)
    foreach ($f in Get-ChildItem -LiteralPath $OriginalDir -Recurse -File) { $f.IsReadOnly = $true }
    Say "Saved a permanent backup of $count original file(s) to $OriginalDir"
}

# --- journaled apply + recovery ------------------------------------------------------------

function Restore-FromJournal([string]$reason) {
    $journalFile = Join-Path $JournalDir 'journal.json'
    if (-not (Test-Path -LiteralPath $journalFile)) {
        Remove-Item $JournalDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    $j = Get-Content -LiteralPath $journalFile -Raw | ConvertFrom-Json
    Say "Rolling back the update to $($j.sha.Substring(0, 7)) ($reason)..." 'Yellow'
    $backup = Join-Path $JournalDir 'before'
    foreach ($name in 'state.json', 'manifest.json') {
        $saved = Join-Path (Join-Path $JournalDir 'state') $name
        $live = Join-Path $StateDir $name
        if (Test-Path -LiteralPath $saved) { Copy-Item -LiteralPath $saved -Destination $live -Force }
        elseif (Test-Path -LiteralPath $live) { Remove-Item -LiteralPath $live -Force }
    }
    foreach ($rel in @($j.touched)) {
        $target = Local-Path $Project $rel
        $saved = Local-Path $backup $rel
        if (Test-Path -LiteralPath $saved) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $saved -Destination $target -Force
        } elseif (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force   # file did not exist before
        }
        $tmp = "$target.skybound-tmp"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
    Remove-Item $JournalDir -Recurse -Force
    Say 'Rollback complete: your project is back to the previous working version.' 'Yellow'
}

function Apply-Plan($snapshot, $plan, [string]$sha, $manifest) {
    $touched = @($plan.Add) + @($plan.Update) + @($plan.Remove)
    if (Test-Path -LiteralPath $JournalDir) { Remove-Item $JournalDir -Recurse -Force }
    $backup = Join-Path $JournalDir 'before'
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($rel in $touched) {
        $target = Local-Path $Project $rel
        if (Test-Path -LiteralPath $target) {
            $dst = Local-Path $backup $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $target -Destination $dst
        }
    }
    $stateBackup = Join-Path $JournalDir 'state'
    New-Item -ItemType Directory -Force -Path $stateBackup | Out-Null
    foreach ($live in $StateFile, $ManifestFile) {
        if (Test-Path -LiteralPath $live) { Copy-Item -LiteralPath $live -Destination $stateBackup }
    }
    Write-JsonAtomic (Join-Path $JournalDir 'journal.json') ([pscustomobject]@{ sha = $sha; touched = $touched; started = (Get-Date -Format s) })
    try {
        foreach ($rel in @($plan.Add) + @($plan.Update)) {
            Put-File (Local-Path $snapshot.Root $rel) (Local-Path $Project $rel)
        }
        foreach ($rel in $plan.Remove) {
            Fault-Point
            Remove-Item -LiteralPath (Local-Path $Project $rel) -Force
        }
        # Verify every managed file now matches the commit exactly.
        foreach ($rel in $snapshot.Files.Keys) {
            if ($plan.Conflicts -contains $rel) { continue }
            $target = Local-Path $Project $rel
            if (-not (Test-Path -LiteralPath $target) -or (Hash $target) -ne $snapshot.Files[$rel]) {
                throw "Verification failed for $rel"
            }
        }
        $newManifest = @{}
        foreach ($rel in $snapshot.Files.Keys) { $newManifest[$rel] = $snapshot.Files[$rel] }
        Write-JsonAtomic $ManifestFile $newManifest
        Write-JsonAtomic $StateFile ([pscustomobject]@{ sha = $sha; syncedAt = (Get-Date -Format s); zipSha256 = $snapshot.ZipHash; scriptVersion = $ScriptVersion })
        Remove-Item $JournalDir -Recurse -Force
    } catch {
        $message = $_.Exception.Message
        Restore-FromJournal "error: $message"
        throw "Update failed and was rolled back: $message"
    }
}

# --- commit resolution ------------------------------------------------------------------------

function Resolve-Target([string]$current) {
    if ($Pin) {
        $c = Invoke-Api "commits/$Pin"
        if (-not $c.sha -or -not $c.sha.StartsWith($Pin.ToLowerInvariant())) { throw "Pinned commit $Pin was not found in $Repo" }
        return [pscustomobject]@{ Sha = $c.sha; Title = ($c.commit.message -split "`n")[0]; Pinned = $true }
    }
    $c = Invoke-Api "commits/$Branch"
    if (-not $c.sha -or $c.sha -notmatch '^[0-9a-f]{40}$') { throw 'GitHub returned no valid commit SHA for the branch' }
    if ($current -and $c.sha -ne $current) {
        $cmp = Invoke-Api "compare/$current...$($c.sha)"
        if ($cmp.status -ne 'ahead') {
            throw "Branch moved $($cmp.status) relative to your synced commit $($current.Substring(0, 7)); not syncing an older or rewritten version. Use -Pin <sha> to choose a commit explicitly."
        }
    }
    return [pscustomobject]@{ Sha = $c.sha; Title = ($c.commit.message -split "`n")[0]; Pinned = $false }
}

function Ensure-Rojo {
    if ($NoRojo) { return }
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return }
    if (Get-NetTCPConnection -LocalPort 34872 -State Listen -ErrorAction SilentlyContinue) { return }
    if (Test-Path -LiteralPath $Rojo) {
        Say 'Rojo is not running - starting "rojo serve" in a new window.' 'Yellow'
        Start-Process -FilePath $Rojo -ArgumentList 'serve' -WorkingDirectory $Project
    } else {
        Say "Rojo is not running and was not found at $Rojo. Start it with: rojo serve" 'Yellow'
    }
}

# --- one sync pass ---------------------------------------------------------------------------------

function Sync-Once {
    $state = Read-JsonTable $StateFile
    $current = if ($state.ContainsKey('sha')) { [string]$state['sha'] } else { '' }
    $target = Resolve-Target $current
    if ($target.Sha -eq $current) { return $false }

    Say "Commit $($target.Sha): $($target.Title)" 'Cyan'
    $snapshot = Get-Snapshot $target.Sha
    try {
        Say ("Downloaded and validated: {0} .luau files, archive SHA-256 {1}" -f $snapshot.LuauCount, $snapshot.ZipHash)
        $manifest = Read-JsonTable $ManifestFile
        $plan = Get-Plan $snapshot $manifest
        $firstSync = -not (Test-Path -LiteralPath $StateFile)
        if ($DryRun -or $firstSync -or $plan.Conflicts.Count -gt 0 -or $plan.Unknown.Count -gt 0) { Show-Plan $plan $target.Sha }
        if ($DryRun) { Say 'Dry run only: nothing was changed.' 'Cyan'; return $false }
        if ($plan.Conflicts.Count -gt 0) {
            throw "Not updating: $($plan.Conflicts.Count) Skybound file(s) were changed locally (marked !). Nothing was modified."
        }
        if ($firstSync) {
            Say 'This is the first sync. Your current files will be backed up permanently before anything changes.' 'Cyan'
            Write-Host 'Type YES to apply these changes: ' -NoNewline -ForegroundColor Cyan
            $answer = [Console]::In.ReadLine()
            if ($answer -cne 'YES') { Say 'Not applied. Nothing was changed.' 'Yellow'; return $false }
            Ensure-OriginalBackup $snapshot
        }
        if ($plan.Add.Count + $plan.Update.Count + $plan.Remove.Count -eq 0) {
            Write-JsonAtomic $StateFile ([pscustomobject]@{ sha = $target.Sha; syncedAt = (Get-Date -Format s); zipSha256 = $snapshot.ZipHash; scriptVersion = $ScriptVersion })
            Say "Already identical to $($target.Sha.Substring(0, 7))." 'Green'
            return $true
        }
        $scriptChanged = ($plan.Add + $plan.Update) -contains 'tools/autosync.ps1'
        Apply-Plan $snapshot $plan $target.Sha $manifest
        Say ("Synced {0}: {1} new, {2} replaced, {3} removed. Rojo will push it into Studio." -f $target.Sha.Substring(0, 7), $plan.Add.Count, $plan.Update.Count, $plan.Remove.Count) 'Green'
        if ($scriptChanged) {
            Say 'A newer sync script was saved to tools\autosync.ps1. It was NOT run; inspect it and restart it yourself if you want it.' 'Magenta'
        }
        return $true
    } finally {
        Remove-Item $snapshot.Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- main ------------------------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Project -PathType Container)) { throw "Project folder not found: $Project" }
if ((Test-Path -LiteralPath $StateDir) -and -not (Test-Path -LiteralPath $StateDir -PathType Container)) {
    throw "$StateDir exists but is not a folder; rename it and run again."
}
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
if (Test-Path -LiteralPath (Join-Path $JournalDir 'journal.json')) {
    Restore-FromJournal 'a previous update was interrupted'
}

Say "Skybound auto-sync v$ScriptVersion -> $Project" 'Cyan'
if ($Pin) { Say "Pinned to commit $Pin" 'Cyan' } else { Say "Following github.com/$Repo ($Branch)" 'Cyan' }

$exitCode = 0
while ($true) {
    try {
        [void](Sync-Once)
        $exitCode = 0
    } catch {
        Say "Sync failed: $($_.Exception.Message)" 'Red'
        $exitCode = 1
    }
    if ($DryRun -or $Once -or $Pin) { break }
    Ensure-Rojo
    Start-Sleep -Seconds $Interval
}
exit $exitCode
