<#
  Installs TimeClock Sync for the current Windows user (no admin needed). Does NOT touch TimeClockLive.ps1.
  1. Copies TimeClockSync.ps1 to %LOCALAPPDATA%\TimeClockSync\
  2. Asks for the fine-grained GitHub token (Contents: read/write on the private sync repo only) and stores it
     encrypted with Windows DPAPI (only this Windows user on this PC can decrypt it).
  3. Tests one sync cycle, then registers a Scheduled Task "TimeClock Sync" that starts hidden at logon and keeps running.
  Usage (from the folder containing these files):
     powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TimeClockSync.ps1
  Options: -Repo owner/name  -FileWrite WhenClosed|Always|Never  -Uninstall
#>
param(
    [string]$Repo = 'vanwidick/timeclock-sync',
    [ValidateSet('Always','WhenClosed','Never')][string]$FileWrite = 'Always',   # needs TimeClock Live v1.0.2+ (reloads the file); WhenClosed for older versions
    [string]$DataPath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'TimeClockLive\timeclock-data.json'),
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'TimeClockSync'; $task = 'TimeClock Sync'
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'TimeClockSync\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Remove-Item -LiteralPath (Join-Path $dir 'token.dat') -Force -ErrorAction SilentlyContinue
    Write-Host 'TimeClock Sync removed (task stopped, token deleted). Log/state left in' $dir; return
}
if (-not (Test-Path -LiteralPath $DataPath)) { throw "TimeClock Live data file not found: $DataPath" }
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'TimeClockSync.ps1') -Destination (Join-Path $dir 'TimeClockSync.ps1') -Force
$sec = Read-Host -AsSecureString 'Paste the fine-grained GitHub token for the PC (input hidden)'
$sec | ConvertFrom-SecureString | Set-Content -LiteralPath (Join-Path $dir 'token.dat') -Encoding ASCII
$script = Join-Path $dir 'TimeClockSync.ps1'
Write-Host 'Testing one sync cycle...'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Once -Repo $Repo -DataPath $DataPath -FileWrite $FileWrite
if ($LASTEXITCODE -ne 0) { throw "Test sync failed - see $dir\sync-log.txt" }
$arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script + '" -Repo "' + $Repo + '" -DataPath "' + $DataPath + '" -FileWrite ' + $FileWrite
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $act -Trigger $trg -Settings $set -Description 'Two-way punch sync between TimeClock Live and the phone (TimeClock Live Lite).' -Force | Out-Null
Start-ScheduledTask -TaskName $task
Write-Host "Installed. Task '$task' is running; log: $dir\sync-log.txt"
