<#
  TimeClock Sync v1.0.0 (companion for TimeClock Live - does NOT modify TimeClockLive.ps1)
  Two-way sync of the punch log between the PC and the phone app (TimeClock Live Lite) through a PRIVATE GitHub repo.

  * Reads   <DataPath>  (timeclock-data.json written by TimeClockLive.ps1) - only the "punches" object is used.
  * Pushes  punches to  https://api.github.com/repos/<Repo>/contents/<RemotePath>  (private repo, fine-grained token).
  * Pulls   phone punches back and merges them by date (3-way merge against the last synced state).
  * Writes  phone punches into <DataPath> ONLY while TimeClock Live is NOT running (default -FileWrite WhenClosed),
            because TimeClockLive.ps1 keeps punches in memory, never re-reads the file, and rewrites it on every punch.
            Until then they are queued (they are safe in the cloud copy) and land the next time the app is closed.
            Only the "punches" value in the file is replaced; profile / pto / alerts / sync / display are left byte-for-byte.
  * Never uploads anything except punches (no profile, no alerts.topic, no sync topic). Never logs the token.

  Token: stored with Windows DPAPI (current user only) in %LOCALAPPDATA%\TimeClockSync\token.dat by Install-TimeClockSync.ps1.
#>
[CmdletBinding()]
param(
    [string]$DataPath   = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'TimeClockLive\timeclock-data.json'),
    [string]$Repo       = 'vanwidick/timeclock-sync',
    [string]$RemotePath = 'timeclock-sync.json',
    [string]$Branch     = 'main',
    [string]$ApiBase    = 'https://api.github.com',
    [string]$StateDir   = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'TimeClockSync' } else { Join-Path $HOME '.timeclocksync' }),
    [int]$IntervalSec   = 20,
    [ValidateSet('WhenClosed','Always','Never')][string]$FileWrite = 'WhenClosed',
    [switch]$Once,
    [switch]$AssumeDesktopRunning,   # test hook
    [switch]$AssumeDesktopClosed     # test hook
)
$ErrorActionPreference = 'Stop'
$SyncVersion = '1.0.0'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$StatePath = Join-Path $StateDir 'state.json'; $LogPath = Join-Path $StateDir 'sync-log.txt'; $TokenPath = Join-Path $StateDir 'token.dat'

function Write-Log([string]$m) {
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8; $fi = Get-Item -LiteralPath $LogPath; if ($fi.Length -gt 1MB) { Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.old') -Force } } catch {}
    Write-Verbose $line
}
function Get-Token {
    if ($env:TCSYNC_TOKEN) { return $env:TCSYNC_TOKEN }   # test / manual override
    if (-not (Test-Path -LiteralPath $TokenPath)) { throw "No token. Run Install-TimeClockSync.ps1 first." }
    $sec = Get-Content -LiteralPath $TokenPath -Raw | ConvertTo-SecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# ---------------------------------------------------------------- punches <-> hashtable of date -> ArrayList of @(kind, sec)
$Kinds = @('in','out','bs','be','lo','li')
function ConvertTo-PunchTable($obj) {
    $t = @{}
    if ($null -eq $obj) { return $t }
    foreach ($pr in $obj.PSObject.Properties) {
        if ($pr.Name -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
        $l = New-Object System.Collections.ArrayList
        foreach ($e in @($pr.Value)) { if ($null -eq $e) { continue }; $e = @($e); if ($e.Count -lt 2) { continue }
            $k = [string]$e[0]; if ($Kinds -notcontains $k) { continue }
            $s = [int][math]::Round([double]$e[1]); if ($s -lt 0) { $s = 0 }; if ($s -gt 86399) { $s = 86399 }
            [void]$l.Add(@($k, $s)) }
        if ($l.Count) { $t[$pr.Name] = $l }
    }
    return $t
}
function ConvertTo-PunchJson($t) {   # compact, sorted by date - same layout TimeClockLive.ps1 writes
    $parts = @(foreach ($k in @($t.Keys | Sort-Object)) { $l = $t[$k]; if (-not $l -or $l.Count -eq 0) { continue }
        '"' + $k + '":[' + ((@($l) | ForEach-Object { '["' + $_[0] + '",' + [int]$_[1] + ']' }) -join ',') + ']' })
    return ('{' + ($parts -join ',') + '}')
}
function Test-DayEq($x, $y) {
    $x = @($x | Where-Object { $null -ne $_ }); $y = @($y | Where-Object { $null -ne $_ })
    if ($x.Count -ne $y.Count) { return $false }
    for ($i = 0; $i -lt $x.Count; $i++) { if ([string]$x[$i][0] -ne [string]$y[$i][0] -or [int]$x[$i][1] -ne [int]$y[$i][1]) { return $false } }
    return $true
}
function Test-PunchEq($a, $b) { return ((ConvertTo-PunchJson $a) -eq (ConvertTo-PunchJson $b)) }
# 3-way merge per date (identical rules to the phone's tcMerge3 in src/merge.js)
function Merge-Punches3($pBase, $pA, $pB) {   # (PowerShell names are case-insensitive: keep these distinct from $A/$B/$C)
    if ($null -eq $pBase) { $pBase = @{} }; if ($null -eq $pA) { $pA = @{} }; if ($null -eq $pB) { $pB = @{} }
    $out = @{}
    $days = @(@($pBase.Keys) + @($pA.Keys) + @($pB.Keys) | Sort-Object -Unique)
    foreach ($d in $days) {
        $dayB = @(); if ($pBase.ContainsKey($d)) { $dayB = @($pBase[$d]) }
        $dayA = @(); if ($pA.ContainsKey($d)) { $dayA = @($pA[$d]) }
        $dayC = @(); if ($pB.ContainsKey($d)) { $dayC = @($pB[$d]) }
        if (Test-DayEq $dayA $dayB) { $r = $dayC } elseif (Test-DayEq $dayC $dayB) { $r = $dayA } elseif (Test-DayEq $dayA $dayC) { $r = $dayA }
        else {
            $cnt = { param($l) $m = @{}; foreach ($e in $l) { $k = [string]$e[0] + ':' + [int]$e[1]; if ($m.ContainsKey($k)) { $m[$k]++ } else { $m[$k] = 1 } }; return $m }
            $cB = & $cnt $dayB; $cA = & $cnt $dayA; $cC = & $cnt $dayC
            $order = New-Object System.Collections.ArrayList; $items = @{}
            foreach ($e in (@($dayA) + @($dayC) + @($dayB))) { $k = [string]$e[0] + ':' + [int]$e[1]; if (-not $items.ContainsKey($k)) { $items[$k] = @([string]$e[0], [int]$e[1]); [void]$order.Add($k) } }
            $tmp = New-Object System.Collections.ArrayList; $i = 0
            foreach ($k in $order) {
                $nb = $(if ($cB.ContainsKey($k)) { $cB[$k] } else { 0 })
                $dA = $(if ($cA.ContainsKey($k)) { $cA[$k] } else { 0 }) - $nb
                $dC = $(if ($cC.ContainsKey($k)) { $cC[$k] } else { 0 }) - $nb
                if ($dA -gt 0 -and $dC -gt 0) { $n = $nb + [math]::Max($dA, $dC) } elseif ($dA -lt 0 -and $dC -lt 0) { $n = $nb + [math]::Min($dA, $dC) } else { $n = $nb + $dA + $dC }
                for ($j = 0; $j -lt $n; $j++) { [void]$tmp.Add([pscustomobject]@{ k = $items[$k][0]; s = $items[$k][1]; i = $i }); $i++ }
            }
            $r = @($tmp | Sort-Object -Property @{ Expression = 's' }, @{ Expression = 'i' } | ForEach-Object { ,@($_.k, $_.s) })
        }
        $l = New-Object System.Collections.ArrayList
        foreach ($e in @($r)) { if ($null -ne $e) { [void]$l.Add(@([string]$e[0], [int]$e[1])) } }
        if ($l.Count) { $out[$d] = $l }
    }
    return $out
}

# ---------------------------------------------------------------- state (last synced canonical S, and file base FB)
function Read-State {
    $s = @{ S = @{}; FB = @{}; fileHash = '' }
    try { if (Test-Path -LiteralPath $StatePath) { $j = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $s.S = ConvertTo-PunchTable $j.S; $s.FB = ConvertTo-PunchTable $j.FB } } catch { Write-Log ('state unreadable, starting fresh: ' + $_.Exception.Message) }
    return $s
}
function Save-State($st) {
    $json = '{"version":"' + $SyncVersion + '","saved":"' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '","S":' + (ConvertTo-PunchJson $st.S) + ',"FB":' + (ConvertTo-PunchJson $st.FB) + '}'
    $tmp = $StatePath + '.tmp'; [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false)); Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

# ---------------------------------------------------------------- local data file
function Read-DataFile {
    for ($try = 0; $try -lt 5; $try++) {
        try { $raw = [IO.File]::ReadAllText($DataPath, [Text.Encoding]::UTF8)
            $j = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
            return @{ Raw = $raw; Punches = (ConvertTo-PunchTable $j.punches) } }
        catch { Start-Sleep -Milliseconds 300 } }
    throw ('cannot read ' + $DataPath)
}
function Test-DesktopRunning {
    if ($AssumeDesktopRunning) { return $true }; if ($AssumeDesktopClosed) { return $false }
    try { $p = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -match 'TimeClockLive\.ps1' }); return ($p.Count -gt 0) }
    catch { return $true }   # unsure -> treat as running (never risk a clobber)
}
function Write-DataFilePunches([string]$expectRaw, $punches) {
    $cur = [IO.File]::ReadAllText($DataPath, [Text.Encoding]::UTF8)
    if ($cur -ne $expectRaw) { Write-Log 'file changed while syncing; retry next cycle'; return $false }
    $pj = ConvertTo-PunchJson $punches
    $rx = [regex]'"punches"\s*:\s*\{[^{}]*\}'   # punch log contains only [] inside, so this is the whole value
    if (-not $rx.IsMatch($cur)) { Write-Log 'punches block not found in data file; not writing'; return $false }
    $new = $rx.Replace($cur, ('"punches":  ' + $pj).Replace('$', '$$'), 1)
    $tmp = $DataPath + '.sync.tmp'
    [IO.File]::WriteAllText($tmp, $new, (New-Object Text.UTF8Encoding $false))
    Copy-Item -LiteralPath $DataPath -Destination ($DataPath + '.bak') -Force
    Move-Item -LiteralPath $tmp -Destination $DataPath -Force
    return $true
}

# ---------------------------------------------------------------- GitHub contents API
function Get-HttpStatus($err) { try { return [int]$err.Exception.Response.StatusCode } catch { return 0 } }
function Invoke-Gh([string]$method, [string]$url, $body) {
    $h = @{ Authorization = ('Bearer ' + (Get-Token)); Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'TimeClockSync/' + $SyncVersion }
    if ($null -ne $body) { return Invoke-RestMethod -Method $method -Uri $url -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 4 -Compress))) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 }
    return Invoke-RestMethod -Method $method -Uri $url -Headers $h -TimeoutSec 30
}
function Get-Remote {
    $url = $ApiBase + '/repos/' + $Repo + '/contents/' + $RemotePath + '?ref=' + $Branch + '&t=' + [DateTime]::UtcNow.Ticks
    try { $r = Invoke-Gh 'GET' $url $null }
    catch { if ((Get-HttpStatus $_) -eq 404) { return @{ Sha = $null; Punches = @{} } }; throw }
    $txt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$r.content -replace '\s', '')))
    $j = $txt.TrimStart([char]0xFEFF) | ConvertFrom-Json
    return @{ Sha = [string]$r.sha; Punches = (ConvertTo-PunchTable $j.punches) }
}
function Set-Remote($punches, $sha) {
    $doc = '{"app":"TimeClock Live Sync","version":"' + $SyncVersion + '","saved":"' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '","by":"pc","punches":' + (ConvertTo-PunchJson $punches) + '}'
    $body = [ordered]@{ message = ('pc sync ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')); content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)); branch = $Branch }
    if ($sha) { $body.sha = $sha }
    $r = Invoke-Gh 'PUT' ($ApiBase + '/repos/' + $Repo + '/contents/' + $RemotePath) $body
    return [string]$r.content.sha
}

# ---------------------------------------------------------------- one sync cycle
function Invoke-SyncCycle($st) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $file = Read-DataFile; $F = $file.Punches
        $rem = Get-Remote; $R = $rem.Punches
        $Sp = Merge-Punches3 $st.FB $F $st.S      # apply the desktop's changes since last cycle onto the synced state
        $N  = Merge-Punches3 $st.S $Sp $R          # then merge with the cloud (phone) copy
        if (-not (Test-PunchEq $N $R)) {
            try { [void](Set-Remote $N $rem.Sha); Write-Log 'pushed punches to cloud' }
            catch { $c = Get-HttpStatus $_; if ($c -eq 409 -or $c -eq 422) { Write-Log ('cloud changed meanwhile (' + $c + '), retrying'); continue }; throw }
        }
        if (-not (Test-PunchEq $N $F)) {
            $can = $false
            if ($FileWrite -eq 'Always') { $can = $true } elseif ($FileWrite -eq 'WhenClosed') { $can = -not (Test-DesktopRunning) }
            if ($can -and (Write-DataFilePunches $file.Raw $N)) { $st.FB = $N; Write-Log 'wrote phone punches into timeclock-data.json' }
            else { $st.FB = $F; if (-not $st.Queued) { Write-Log 'phone punches waiting: TimeClock Live is running (they are kept in the cloud and written when it is closed)' }; $st.Queued = $true }
        } else { $st.FB = $F; $st.Queued = $false }
        $st.S = $N; Save-State $st
        return $true
    }
    return $false
}

Write-Log ('TimeClock Sync v' + $SyncVersion + ' start; data=' + $DataPath + ' repo=' + $Repo + '/' + $RemotePath + ' fileWrite=' + $FileWrite)
$st = Read-State; $st.Queued = $false
$lastErr = ''
while ($true) {
    try { [void](Invoke-SyncCycle $st); $lastErr = '' }
    catch { $m = $_.Exception.Message; if ($m -ne $lastErr) { Write-Log ('sync error: ' + $m) }; $lastErr = $m; if ($Once) { throw } }
    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSec
}
