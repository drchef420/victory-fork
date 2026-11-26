# One test run of this fork, start to finish, for someone who just wants to
# press go. Run it from the repository folder:
#
#   powershell -ExecutionPolicy Bypass -File tools\fork-test.ps1
#
# It asks for the game folder, builds, writes the ray-tracing builder report,
# starts the game (once or twice), reads the frame rate from the window
# title while you play, asks two yes/no questions, and writes everything
# worth reading into one file, summary.txt, in a results folder it opens at
# the end. Nothing is uploaded anywhere.

# 'Continue', not 'Stop': Windows PowerShell turns a program's log lines on
# its error output into errors, which 'Stop' would end the script at.
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Say($text) { Write-Host ''; Write-Host $text -ForegroundColor Cyan }

# --- The game folder -------------------------------------------------------
Say 'Pick the folder that holds your copy of the game.'
$game = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'The folder that holds your copy of the game'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $game = $dialog.SelectedPath }
} catch { }
if (-not $game) { $game = (Read-Host 'Type or paste the game folder path').Trim('"', ' ') }
if (-not (Test-Path -LiteralPath $game -PathType Container)) { throw "Not a folder: $game" }
# (a trailing backslash would escape the closing quote of the argument)
if ($game.EndsWith('\')) { $game = $game + '.' }
$env:VICTORY_GAME_DIR = $game
if ($game.StartsWith($repo, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The game folder must not be inside the victory-fork folder.'
}

# The game's program: the .exe files at the top of the folder, largest first.
$exes = @(Get-ChildItem -LiteralPath $game -Filter *.exe -File | Sort-Object Length -Descending)
if ($exes.Count -eq 0) { throw "No .exe file at the top of $game" }
$exe = $exes[0].FullName
if ($exes.Count -gt 1) {
    Say 'Which of these is the game? (Usually the first, the largest.)'
    for ($i = 0; $i -lt $exes.Count; $i++) {
        Write-Host ("  {0}) {1}  ({2:N0} MB)" -f ($i + 1), $exes[$i].Name, ($exes[$i].Length / 1MB))
    }
    $pick = Read-Host 'Number (Enter for 1)'
    if ($pick) { $exe = $exes[[int]$pick - 1].FullName }
}

$results = Join-Path $HOME ('victory-results\' + (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
New-Item -ItemType Directory -Force -Path $results | Out-Null
$summary = Join-Path $results 'summary.txt'
function Note($text) { Add-Content -LiteralPath $summary -Value $text }
$started = Get-Date
Note "fork test run, $(Get-Date)"
Note "branch: $(git branch --show-current)  commit: $(git rev-parse --short HEAD)"
Note "game program: $(Split-Path -Leaf $exe)"
try {
    $gpu = (Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name) -join ', '
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    Note "PC: $gpu, $ram GB memory"
    # A 16 GB PC pages the title's world to disk (31,000 pages a second read
    # back in a 2026-11-25 run): one frame takes 20-45 s and the title's own
    # hang check ends it. A paging file Windows grows on demand stalls too.
    $os = Get-CimInstance Win32_OperatingSystem
    $pf = @(Get-CimInstance Win32_PageFileSetting)
    $fixed = $pf.Count -gt 0 -and ($pf | Where-Object { $_.InitialSize -gt 0 -and $_.InitialSize -eq $_.MaximumSize }).Count -gt 0
    Note ("commit limit {0:N0} GB; paging file {1}" -f ($os.TotalVirtualMemorySize / 1MB), $(if ($fixed) { "fixed $($pf[0].InitialSize) MB" } else { 'managed by Windows' }))
    if ($ram -lt 30) {
        Say "Note: this PC has $ram GB of memory. The game's world needs about 32 GB here: expect freezes and a crash a few minutes in."
    }
    if (-not $fixed) {
        Say 'Note: the paging file is managed by Windows. Set a fixed size (Initial = Maximum = 32768 MB) under System Properties > Advanced > Performance > Virtual memory, then restart.'
    }
} catch { }

# --- Build -----------------------------------------------------------------
Say 'Updating and building (a few minutes the first time)...'
git pull --ff-only
cargo build --release -p victory
if ($LASTEXITCODE -ne 0) { throw 'The build failed: send the red text above.' }
$victory = Join-Path $repo 'target\release\victory.exe'

# --- 1. The ray-tracing builder report (no window; 5-15 minutes) -----------
$gpuName = "$gpu"   # (empty if the question above failed: then as for NVIDIA)
Say 'Step 1 of 2: checking the game''s ray-tracing programs. No window opens; this takes a while.'
$env:VICTORY_WAVE_WHY = '1'
if ($gpuName -notmatch 'AMD|Radeon') { $env:VICTORY_HOST_WAVE = '32' }
Start-Process -FilePath $victory -ArgumentList @('translate', "`"$game`"", '--pipelines') -Wait -NoNewWindow `
    -RedirectStandardOutput (Join-Path $results 'builder.txt') -RedirectStandardError (Join-Path $results 'builder-log.txt')
Remove-Item Env:VICTORY_WAVE_WHY, Env:VICTORY_HOST_WAVE -ErrorAction SilentlyContinue
Note ''
Note '=== ray-tracing builder report ==='
$builder = @(Select-String -LiteralPath (Join-Path $results 'builder.txt') -Pattern '^builder|^  builder' | ForEach-Object { $_.Line })
if ($builder.Count -eq 0) { Note '(no builder lines: see builder.txt)' } else { $builder | ForEach-Object { Note $_ } }

# --- 2. Play ---------------------------------------------------------------
function Play($name, $extra) {
    $log = Join-Path $results "$name.txt"
    Say "Starting the game ($name). Play into the first room you can walk around in, look around for a minute, then close the game window."
    Write-Host 'Loading takes a minute or more. The frame rate is read from the window title while you play.'
    foreach ($k in $extra.Keys) { Set-Item -Path "Env:$k" -Value $extra[$k] }
    $p = Start-Process -FilePath $victory -ArgumentList @('run', "`"$exe`"", '--execute') `
        -RedirectStandardError $log -RedirectStandardOutput "$log.out" -PassThru -NoNewWindow
    $titles = @()
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 5
        try {
            $t = (Get-Process -Id $p.Id -ErrorAction Stop).MainWindowTitle
            if ($t -match 'VIctory') { $titles += "$(Get-Date -Format 'HH:mm:ss') $t" }
        } catch { }
    }
    foreach ($k in $extra.Keys) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
    $walls = Read-Host 'Did the first room have its walls? (y/n/not sure)'
    $look = Read-Host 'Anything else you noticed? (Enter to skip)'
    Note ''
    Note "=== $name ==="
    Note "walls: $walls"
    if ($look) { Note "noticed: $look" }
    Note 'frame rate from the window title (every 5 s, last 12 samples):'
    $titles | Select-Object -Last 12 | ForEach-Object { Note "  $_" }
    Note 'memory question and warnings from the log:'
    $lines = @(Select-String -LiteralPath $log -Pattern 'device ready on|the title asks how much memory|ray-tracing structure builder|WARN|ERROR|panicked' |
        ForEach-Object { $_.Line } | Select-Object -First 60)
    if ($lines.Count -eq 0) { Note '  (none)' } else { $lines | ForEach-Object { Note "  $_" } }
    return $log
}

$first = Play 'run1' @{}
$asks = Select-String -LiteralPath $first -Pattern 'the title asks how much memory' -Quiet
if ($asks) {
    Say 'The game asked how much memory it uses. One more run, telling it only its own memory.'
    Play 'run2-own-memory' @{ VICTORY_TITLE_USED = 'own' } | Out-Null
} else {
    Note ''
    Note 'run2 skipped: the game never asked how much memory it uses.'
}

# crashes.log is written beside the title's temp folder, under the data
# folder `victory config` prints (data_dir\<title id>\crashes.log).
$dataDir = (& $victory config 2>$null | Select-String '^data_dir\s*:\s*(.+)$' |
    ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } | Select-Object -First 1)
$crashLogs = @()
if ($dataDir -and (Test-Path -LiteralPath $dataDir)) {
    $crashLogs = @(Get-ChildItem -LiteralPath $dataDir -Recurse -Filter crashes.log -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started })
}
foreach ($c in $crashLogs) {
    Note ''
    Note "=== $($c.FullName) (last 40 lines) ==="
    Get-Content -LiteralPath $c.FullName -Tail 40 | ForEach-Object { Note $_ }
}
if ($crashLogs.Count -eq 0) { Note ''; Note "no crashes.log written during this test (looked under $dataDir)" }

Say "Done. Send summary.txt from the folder that opens now (drag it into the chat, or paste its text)."
Write-Host $summary
Start-Process explorer.exe $results
