# Runs the shared vectors (../sync-test/vectors.json) through Merge-Punches3 extracted from TimeClockSync.ps1
Set-StrictMode -Version 2.0
$src = Get-Content -Raw (Join-Path $PSScriptRoot 'TimeClockSync.ps1')
$start = $src.IndexOf('$Kinds = @('); $end = $src.IndexOf('# ---------------------------------------------------------------- state')
Invoke-Expression $src.Substring($start, $end - $start)
$V = Get-Content -Raw (Join-Path $PSScriptRoot '..\sync-test\vectors.json'.Replace('\', [IO.Path]::DirectorySeparatorChar)) | ConvertFrom-Json
$ok = $true
foreach ($v in $V) { $got = ConvertTo-PunchJson (Merge-Punches3 (ConvertTo-PunchTable $v.base) (ConvertTo-PunchTable $v.a) (ConvertTo-PunchTable $v.b))
    $want = ConvertTo-PunchJson (ConvertTo-PunchTable $v.want)
    if ($got -eq $want) { "PASS ps $($v.name)" } else { "FAIL ps $($v.name) got $got want $want"; $ok = $false } }
$L = Get-Content -Raw (Join-Path $PSScriptRoot '..\sync-test\limit_vectors.json'.Replace('\', [IO.Path]::DirectorySeparatorChar)) | ConvertFrom-Json
foreach ($v in $L) { $got = ConvertTo-PunchJson (Limit-Breaks (ConvertTo-PunchTable $v.in)); $want = ConvertTo-PunchJson (ConvertTo-PunchTable $v.want)
    if ($got -eq $want) { "PASS ps limit $($v.name)" } else { "FAIL ps limit $($v.name) got $got"; $ok = $false } }
if (-not $ok) { exit 1 }
