<#
  TimeClock Sync v1.1.0 (companion for TimeClock Live - does NOT modify TimeClockLive.ps1)
  Two-way sync of the punch log between the PC and the phone app (TimeClock Live Lite) through a PRIVATE GitHub repo.
  Requires TimeClock Live v1.0.2+ (reloads timeclock-data.json on change and 3-way merges punches from disk before saving).

  * Reads   <DataPath> (timeclock-data.json) when its LastWriteTime/size changes - only "punches" is used.
            Opened with FileShare Read|Write|Delete, never held open.
  * Pushes  punches to https://api.github.com/repos/<Repo>/contents/<RemotePath> (private repo, fine-grained token).
  * Pulls   phone punches (conditional GET, ETag) and merges them by date (3-way against the last synced state).
  * Writes  merged punches back live (default -FileWrite Always): re-reads the file right before writing (if the desktop
            changed it meanwhile, re-merges first), replaces ONLY the "punches" value (every other key - profile, pto, alerts,
            display, sync, days... - is written back byte-for-byte), writes UTF-8 to timeclock-data.json.lite.tmp in the same
            folder and swaps it in with File.Replace (previous file kept as timeclock-data.json.bak, like the app does).
            Its own write is remembered so it is not pushed back (no ping-pong).
  * Punch rules: Central yyyy-MM-dd keys, seconds 0-86399, kinds in/out/bs/be/lo/li, at most 2 breaks a day.
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
    [int]$IntervalSec   = 10,
    [ValidateSet('Always','WhenClosed','Never')][string]$FileWrite = 'Always',   # WhenClosed = legacy mode for TimeClock Live < 1.0.2
    [switch]$Once,
    [int]$Cycles = 0,                # 0 = run forever (test hook: stop after N cycles)
    [switch]$AssumeDesktopRunning,   # test hook
    [switch]$AssumeDesktopClosed,    # test hook
    [string]$TestPreWriteHook = ''   # test hook: script run just before the pre-write re-read (simulates a desktop save racing us)
)
$ErrorActionPreference = 'Stop'
$SyncVersion = '1.1.0'
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
        $dt = [datetime]::MinValue; if (-not [datetime]::TryParseExact($pr.Name, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) { continue }
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

# At most 2 breaks a day (same rules as tcLimitBreaks in the phone app). A 3rd+ "bs" is dropped; if no break was open it is
# dropped together with the "be" that closes it (if a break was still open, that "be" still ends it and is kept).
function Limit-Breaks($t) {
    $out = @{}
    foreach ($d in @($t.Keys)) { $n = 0; $open = $false; $skipBe = $false; $l = New-Object System.Collections.ArrayList
        foreach ($e in @($t[$d])) { $k = [string]$e[0]
            if ($k -eq 'bs') { $n++; if ($n -gt 2) { if (-not $open) { $skipBe = $true }; continue }; $open = $true; $skipBe = $false }
            elseif ($k -eq 'be') { if ($skipBe) { $skipBe = $false; continue }; $open = $false }
            else { $open = $false; $skipBe = $false }
            [void]$l.Add(@($k, [int]$e[1])) }
        if ($l.Count) { $out[$d] = $l } }
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
function Get-FileSig { $fi = New-Object IO.FileInfo $DataPath; $fi.Refresh(); if (-not $fi.Exists) { return '' }; return ([string]$fi.LastWriteTimeUtc.Ticks + ':' + [string]$fi.Length) }
function Read-Shared([string]$path) {   # never blocks the app: share Read|Write|Delete, closed right away
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $sr = New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding $false), $true); try { return $sr.ReadToEnd() } finally { $sr.Dispose() } } finally { $fs.Dispose() }
}
function Read-DataFile {
    for ($try = 0; $try -lt 5; $try++) {
        try { $sig = Get-FileSig; $raw = Read-Shared $DataPath
            $j = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
            if ($null -eq $j) { throw 'empty' }
            return @{ Raw = $raw; Sig = $sig; Punches = (ConvertTo-PunchTable $j.punches) } }
        catch { Start-Sleep -Milliseconds 300 } }
    throw ('cannot read ' + $DataPath)
}
function Test-DesktopRunning {
    if ($AssumeDesktopRunning) { return $true }; if ($AssumeDesktopClosed) { return $false }
    try { $p = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -match 'TimeClockLive\.ps1' }); return ($p.Count -gt 0) }
    catch { return $true }   # unsure -> treat as running (never risk a clobber)
}
$PunchRx = [regex]'"punches"\s*:\s*\{[^{}]*\}'   # the punch log holds only [] inside, so this is the whole value
# Replace only the "punches" value of $raw; atomic swap via temp file in the same folder + File.Replace. Returns new sig or $null.
function Write-DataFilePunches([string]$raw, $punches) {
    if (-not $PunchRx.IsMatch($raw)) { Write-Log 'punches block not found in data file; not writing'; return $null }
    $new = $PunchRx.Replace($raw, ('"punches":  ' + (ConvertTo-PunchJson $punches)).Replace('$', '$$'), 1)
    try { [void]($new.TrimStart([char]0xFEFF) | ConvertFrom-Json) } catch { Write-Log 'refusing to write: result is not valid JSON'; return $null }
    $tmp = $DataPath + '.lite.tmp'; $bak = $DataPath + '.bak'
    [IO.File]::WriteAllText($tmp, $new, (New-Object Text.UTF8Encoding $false))
    for ($try = 0; $try -lt 10; $try++) {
        try { [IO.File]::Replace($tmp, $DataPath, $bak, $true); return (Get-FileSig) }
        catch { Start-Sleep -Milliseconds 150 } }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Log 'could not replace data file (busy); will retry'; return $null
}

# ---------------------------------------------------------------- GitHub contents API
function Get-HttpStatus($err) { try { return [int]$err.Exception.Response.StatusCode } catch { return 0 } }
function Invoke-Gh([string]$method, [string]$url, $body, $extra) {
    $h = @{ Authorization = ('Bearer ' + (Get-Token)); Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'TimeClockSync/' + $SyncVersion }
    if ($extra) { foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] } }
    if ($null -ne $body) { return Invoke-RestMethod -Method $method -Uri $url -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 4 -Compress))) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 }
    return Invoke-RestMethod -Method $method -Uri $url -Headers $h -TimeoutSec 30
}
$script:RemoteCache = $null   # last GET result + ETag; a 304 does not count against the GitHub rate limit
function Get-Remote {
    $url = $ApiBase + '/repos/' + $Repo + '/contents/' + $RemotePath + '?ref=' + $Branch
    $hdr = $null; if ($script:RemoteCache -and $script:RemoteCache.ETag) { $hdr = @{ 'If-None-Match' = $script:RemoteCache.ETag } }
    $h = @{ Authorization = ('Bearer ' + (Get-Token)); Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'TimeClockSync/' + $SyncVersion }
    if ($hdr) { $h['If-None-Match'] = $hdr['If-None-Match'] }
    try { $resp = Invoke-WebRequest -Method GET -Uri $url -Headers $h -TimeoutSec 30 -UseBasicParsing }
    catch { $c = Get-HttpStatus $_
        if ($c -eq 304 -and $script:RemoteCache) { return $script:RemoteCache }
        if ($c -eq 404) { $script:RemoteCache = $null; return @{ Sha = $null; Punches = @{}; ETag = $null } }; throw }
    if ([int]$resp.StatusCode -eq 304 -and $script:RemoteCache) { return $script:RemoteCache }
    $body = $resp.Content; if ($body -is [byte[]]) { $body = [Text.Encoding]::UTF8.GetString($body) }
    $r = $body | ConvertFrom-Json
    $txt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$r.content -replace '\s', '')))
    $j = $txt.TrimStart([char]0xFEFF) | ConvertFrom-Json
    $et = $null; try { $et = [string]@($resp.Headers['ETag'])[0] } catch {}
    $script:RemoteCache = @{ Sha = [string]$r.sha; Punches = (ConvertTo-PunchTable $j.punches); ETag = $et }
    return $script:RemoteCache
}
function Set-Remote($punches, $sha) {
    $doc = '{"app":"TimeClock Live Sync","version":"' + $SyncVersion + '","saved":"' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '","by":"pc","punches":' + (ConvertTo-PunchJson $punches) + '}'
    $body = [ordered]@{ message = ('pc sync ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')); content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)); branch = $Branch }
    if ($sha) { $body.sha = $sha }
    $r = Invoke-Gh 'PUT' ($ApiBase + '/repos/' + $Repo + '/contents/' + $RemotePath) $body
    return [string]$r.content.sha
}

# ---------------------------------------------------------------- one sync cycle
# State: S = last synced (canonical) punches, FB = punches last seen in / written to the data file, FileSig = its LastWriteTime:size.
function Invoke-SyncCycle($st) {
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $sig = Get-FileSig; if (-not $sig) { throw ('data file not found: ' + $DataPath) }
        if ($sig -ne $st.FileSig -or $null -eq $st.FileRaw) { $file = Read-DataFile; $st.FileRaw = $file.Raw; $F = $file.Punches; $fileChanged = ($sig -ne $st.FileSig) }
        else { $F = $st.FB; $fileChanged = $false }   # unchanged since we last read/wrote it (incl. our own write) -> nothing new from the desktop
        $rem = Get-Remote; $R = $rem.Punches
        $Sp = Merge-Punches3 $st.FB $F $st.S                    # the desktop's changes since last cycle, applied onto the synced state
        $N  = Limit-Breaks (Merge-Punches3 $st.S $Sp $R)        # merged with the cloud (phone) copy
        if (-not (Test-PunchEq $N $R)) {
            try { [void](Set-Remote $N $rem.Sha); $script:RemoteCache = $null; Write-Log ('pushed punches to cloud' + $(if ($fileChanged) { ' (desktop change)' } else { '' })) }
            catch { $c = Get-HttpStatus $_; if ($c -eq 409 -or $c -eq 422) { $script:RemoteCache = $null; Write-Log ('cloud changed meanwhile (' + $c + '), re-merging'); continue }; throw }
        }
        if (-not (Test-PunchEq $N $F)) {
            $can = $false
            if ($FileWrite -eq 'Always') { $can = $true } elseif ($FileWrite -eq 'WhenClosed') { $can = -not (Test-DesktopRunning) }
            if (-not $can) { $st.FB = $F; $st.FileSig = $sig; $st.S = $N; Save-State $st; return $true }
            # re-read immediately before writing; if the desktop saved meanwhile, merge that first (next attempt)
            if ($TestPreWriteHook -and -not $script:HookRan) { $script:HookRan = $true; & $TestPreWriteHook }
            $now = Read-DataFile
            if (-not (Test-PunchEq $now.Punches $F)) { $st.FB = $F; $st.S = $N; $st.FileSig = '#changed'; Write-Log 'desktop saved meanwhile; re-merging before write'; continue }
            $newSig = Write-DataFilePunches $now.Raw $N
            if ($newSig) { $st.FB = $N; $st.FileSig = $newSig; $st.FileRaw = $null; Write-Log 'wrote cloud punches into timeclock-data.json' }
            else { $st.FB = $F; $st.FileSig = '#retry' }
        } else { $st.FB = $F; $st.FileSig = $sig }
        $st.S = $N; Save-State $st
        return $true
    }
    return $false
}

Write-Log ('TimeClock Sync v' + $SyncVersion + ' start; data=' + $DataPath + ' repo=' + $Repo + '/' + $RemotePath + ' fileWrite=' + $FileWrite)
$st = Read-State; $st.FileSig = ''; $st.FileRaw = $null
$lastErr = ''; $n = 0
while ($true) {
    try { [void](Invoke-SyncCycle $st); $lastErr = '' }
    catch { $m = $_.Exception.Message; if ($m -ne $lastErr) { Write-Log ('sync error: ' + $m) }; $lastErr = $m; if ($Once) { throw } }
    if ($Once) { break }
    $n++; if ($Cycles -gt 0 -and $n -ge $Cycles) { break }
    Start-Sleep -Seconds $IntervalSec
}
