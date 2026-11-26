# The second test run: the game with the ray-tracing structure builder on.
# Run fork-test.ps1 first (it builds victory.exe), then from the repo folder:
#
#   powershell -ExecutionPolicy Bypass -File tools\builder-run.ps1
#
# Sets VICTORY_BVH_BUILDER=1 VICTORY_FIRSTLANE_OWN=1 VICTORY_BVH_QUARANTINE=1
# for this run only, and writes the log and a short summary to a results folder.
# With -NoQuarantine it leaves VICTORY_BVH_QUARANTINE out: what the builder
# stores then goes back into the title's memory, and the title gets its
# results (sizes, counters) back.
#
#   powershell -ExecutionPolicy Bypass -File tools\builder-run.ps1 -NoQuarantine

#
# With -NoBuilder it runs the game with only the bounds watch on: the control
# for a builder run, from the same save.
#
#   powershell -ExecutionPolicy Bypass -File tools\builder-run.ps1 -NoBuilder

param([switch]$NoQuarantine, [switch]$NoBuilder)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo
function Say($text) { Write-Host ''; Write-Host $text -ForegroundColor Cyan }

$victory = Join-Path $repo 'target\release\victory.exe'
if (-not (Test-Path -LiteralPath $victory)) { throw 'No target\release\victory.exe: run tools\fork-test.ps1 first.' }

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
if ($game.EndsWith('\')) { $game = $game + '.' }
$env:VICTORY_GAME_DIR = $game

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

$kind = if ($NoBuilder) { '_nobuilder' } elseif ($NoQuarantine) { '_builder-noquarantine' } else { '_builder' }
$results = Join-Path $HOME ('victory-results\' + (Get-Date -Format 'yyyy-MM-dd_HH-mm') + $kind)
New-Item -ItemType Directory -Force -Path $results | Out-Null
$summary = Join-Path $results 'summary.txt'
function Note($text) { Add-Content -LiteralPath $summary -Value $text }
$started = Get-Date
Note "builder run, $(Get-Date)"
Note "branch: $(git branch --show-current)  commit: $(git rev-parse --short HEAD)"
$switches = @{ VICTORY_BVH_BUILDER = '1'; VICTORY_FIRSTLANE_OWN = '1'; VICTORY_BOUNDS_WATCH = '1' }
if ($NoBuilder) { $switches = @{ VICTORY_BOUNDS_WATCH = '1' } }
elseif (-not $NoQuarantine) { $switches.VICTORY_BVH_QUARANTINE = '1' }
Note ('switches: ' + (($switches.Keys | Sort-Object | ForEach-Object { "$_=$($switches[$_])" }) -join ' '))

foreach ($k in $switches.Keys) { Set-Item -Path "Env:$k" -Value $switches[$k] }

$log = Join-Path $results 'builder-run.txt'
Say 'Starting the game with the ray-tracing builder on. Play into the first room, look around for a minute, then close the game window.'
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
foreach ($k in $switches.Keys) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }

$elapsed = (Get-Date) - $started
$walls = Read-Host 'Did you reach the first room? Did it have its walls? (describe briefly)'
Note "ran for $([int]$elapsed.TotalMinutes) min $($elapsed.Seconds) s; exit code $($p.ExitCode)"
Note "player: $walls"
Note 'frame rate from the window title (last 12 samples):'
$titles | Select-Object -Last 12 | ForEach-Object { Note "  $_" }
# The builder's own lines apart: in the last run the first 80 warnings
# ended minutes before the builder started.
Note 'the card, the builder and the memory copies it numbers:'
$lines = @(Select-String -LiteralPath $log -Pattern 'device ready on|ray-tracing structure builder|quarantin|copies numbered|no number left|shaders touched pages that had no copy|carries empty bounds' |
    ForEach-Object { $_.Line } | Select-Object -First 100)
if ($lines.Count -eq 0) { Note '  (none)' } else { $lines | ForEach-Object { Note "  $_" } }
Note 'errors, and the last 40 warnings, from the log:'
$lines = @(Select-String -LiteralPath $log -Pattern 'ERROR|panicked' | ForEach-Object { $_.Line } | Select-Object -First 20) +
    @(Select-String -LiteralPath $log -Pattern 'WARN' | ForEach-Object { $_.Line } | Select-Object -Last 40)
if ($lines.Count -eq 0) { Note '  (none)' } else { $lines | ForEach-Object { Note "  $_" } }

$dataDir = (& $victory config 2>$null | Select-String '^data_dir\s*:\s*(.+)$' |
    ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } | Select-Object -First 1)
if ($dataDir -and (Test-Path -LiteralPath $dataDir)) {
    Get-ChildItem -LiteralPath $dataDir -Recurse -Filter crashes.log -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started } | ForEach-Object {
            Note ''; Note "=== $($_.FullName) (last 40 lines) ==="
            Get-Content -LiteralPath $_.FullName -Tail 40 | ForEach-Object { Note $_ }
        }
}

Say 'Done. Send summary.txt from the folder that opens now.'
Write-Host $summary
Start-Process explorer.exe $results
