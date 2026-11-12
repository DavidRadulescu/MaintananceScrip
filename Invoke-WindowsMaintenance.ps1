<#
.SYNOPSIS
    Windows health check and maintenance.
.DESCRIPTION
    Flow:
      1. System state     OS version, uptime
      2. Safety net       restore point                  -CreateRestorePoint
      3. Updates          Windows Update, Defender, apps  -InstallWindowsUpdates -UpdateDefender -UpdateApps
      4. Cleanup          temp files, component store    -CleanTemp -CleanComponentStore
      5. Optimize         defrag HDDs, retrim SSDs       -OptimizeDrives
      6. Repair           DISM, then SFC                 -Repair
      7. Storage          free space, disk health, optimization schedule
      8. Security         BitLocker, Secure Boot, TPM
      9. Backup           age of newest file in -BackupPath
     10. Diagnostics      event log, startup items, pending restart
     11. Summary          table, CSV report, exit code (0 OK, 1 WARN, 2 FAIL)

    Without switches it only reports. Run as Administrator in Windows PowerShell 5.1.
.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1
.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -CreateRestorePoint -UpdateDefender -UpdateApps -CleanTemp
.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -CleanTemp -OptimizeDrives
.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -InstallWindowsUpdates -OptimizeDrives -WhatIf
.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -Repair
.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -BackupPath 'D:\Backups' -BackupMaxAgeDays 3
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$CreateRestorePoint,
    [switch]$InstallWindowsUpdates,
    [switch]$UpdateDefender,
    [switch]$UpdateApps,
    [switch]$CleanTemp,
    [switch]$CleanComponentStore,
    [switch]$OptimizeDrives,
    [switch]$Repair,
    [string]$BackupPath,
    [int]$BackupMaxAgeDays      = 7,
    [int]$TempMaxAgeDays        = 7,
    [int]$MinFreePercent        = 15,
    [int]$MaxUptimeDays         = 7,
    [int]$MaxDaysSinceWUInstall = 35,
    [int]$MaxDaysSinceOptimize  = 35,
    [int]$EventLookbackDays     = 7,
    [int]$LogRetentionDays      = 60,
    [string]$LogDir             = (Join-Path $env:ProgramData 'WinMaintenance')
)
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Cmdlet   = $PSCmdlet
$script:UpdateRebootRequired = $false
function Add-Finding {
    param(
        [string]$Area,
        [ValidateSet('OK', 'INFO', 'WARN', 'FAIL')][string]$Status,
        [string]$Detail
    )
    $script:Findings.Add([pscustomobject]@{ Status = $Status; Area = $Area; Detail = $Detail })
    $colors = @{ OK = 'Green'; INFO = 'Gray'; WARN = 'Yellow'; FAIL = 'Red' }
    Write-Host ('[{0,-4}] {1}: {2}' -f $Status, $Area, $Detail) -ForegroundColor $colors[$Status]
}
function Invoke-Check {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        Add-Finding $Name 'INFO' "Not available on this system ($($_.Exception.CommandName))"
    }
    catch {
        Add-Finding $Name 'WARN' "Check could not run: $($_.Exception.Message)"
    }
}
function Confirm-Action {
    param([string]$Target, [string]$Action)
    $script:Cmdlet.ShouldProcess($Target, $Action)
}
New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $LogDir "maintenance-$stamp.log") -WhatIf:$false | Out-Null
try {
    Write-Host "Windows maintenance on $env:COMPUTERNAME, $(Get-Date)" -ForegroundColor Cyan
    if ($WhatIfPreference) { Write-Host 'WhatIf mode: no changes will be made.' -ForegroundColor Cyan }
    Invoke-Check 'OS version' {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $detail = '{0} {1} (build {2}.{3})' -f $os.Caption, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR
        if ($os.ProductType -eq 1 -and [int]$cv.CurrentBuild -lt 22000) {
            Add-Finding 'OS version' 'WARN' "$detail - Windows 10 no longer gets security updates unless enrolled in ESU"
        }
        else {
            Add-Finding 'OS version' 'INFO' $detail
        }
    }
    Invoke-Check 'Uptime' {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $days = [math]::Round(((Get-Date) - $boot).TotalDays, 1)
        if ($days -gt $MaxUptimeDays) {
            Add-Finding 'Uptime' 'WARN' "$days days since last real restart (Fast Startup shutdowns do not count)"
        }
        else {
            Add-Finding 'Uptime' 'OK' "$days days since last restart"
        }
    }
    Invoke-Check 'Restore point' {
        if ($CreateRestorePoint -and (Confirm-Action 'System Restore' 'Create restore point')) {
            Checkpoint-Computer -Description "Maintenance $(Get-Date -Format 'yyyy-MM-dd')" `
                -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue
        }
        $latest = Get-ComputerRestorePoint -ErrorAction Stop |
            Sort-Object SequenceNumber -Descending | Select-Object -First 1
        if (-not $latest) {
            Add-Finding 'Restore point' 'WARN' "None found - System Protection may be off for $env:SystemDrive"
            return
        }
        $created = [Management.ManagementDateTimeConverter]::ToDateTime($latest.CreationTime)
        $age = [math]::Round(((Get-Date) - $created).TotalDays, 1)
        Add-Finding 'Restore point' 'OK' "Latest: '$($latest.Description)' ($age days ago)"
    }
    Invoke-Check 'Windows Update' {
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $lastOk = $au.Results.LastInstallationSuccessDate
        if ($lastOk) {
            $since = [math]::Round(((Get-Date) - [datetime]$lastOk).TotalDays)
            $status = if ($since -gt $MaxDaysSinceWUInstall) { 'WARN' } else { 'OK' }
            Add-Finding 'Windows Update' $status "Last successful install $since days ago"
        }
        Write-Host 'Searching for Windows updates (can take a few minutes)...'
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result   = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        if ($result.Updates.Count -eq 0) {
            Add-Finding 'Windows Update' 'OK' 'No pending updates'
            return
        }
        $titles = foreach ($u in $result.Updates) { $u.Title }
        Add-Finding 'Windows Update' 'WARN' "$($result.Updates.Count) pending: $($titles -join '; ')"
        if ($InstallWindowsUpdates -and (Confirm-Action "$($result.Updates.Count) Windows update(s)" 'Download and install')) {
            $collection = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $result.Updates) {
                if (-not $u.EulaAccepted) { $u.AcceptEula() }
                [void]$collection.Add($u)
            }
            Write-Host 'Downloading updates...'
            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $collection
            [void]$downloader.Download()
            Write-Host 'Installing updates...'
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $collection
            $install = $installer.Install()
            $script:UpdateRebootRequired = $install.RebootRequired
            $status = if ($install.ResultCode -eq 2) { 'OK' } else { 'FAIL' }
            Add-Finding 'Windows Update' $status "Install result code $($install.ResultCode); restart required: $($install.RebootRequired)"
        }
    }
    Invoke-Check 'Defender' {
        $mp = Get-MpComputerStatus
        if ($mp.AMRunningMode -and $mp.AMRunningMode -ne 'Normal') {
            Add-Finding 'Defender' 'INFO' "Running in '$($mp.AMRunningMode)' - another antivirus is probably primary"
            return
        }
        if ($UpdateDefender -and (Confirm-Action 'Defender security intelligence' 'Update')) {
            Update-MpSignature
            $mp = Get-MpComputerStatus
        }
        if (-not $mp.RealTimeProtectionEnabled) {
            Add-Finding 'Defender' 'FAIL' 'Real-time protection is OFF'
        }
        if ($null -ne $mp.IsTamperProtected -and -not $mp.IsTamperProtected) {
            Add-Finding 'Defender' 'WARN' 'Tamper Protection is off (malware can disable Defender settings)'
        }
        $sigAge = $mp.AntivirusSignatureAge
        $status = if ($sigAge -gt 3) { 'WARN' } else { 'OK' }
        Add-Finding 'Defender' $status "Real-time protection: $($mp.RealTimeProtectionEnabled); signatures $sigAge day(s) old"
    }
    Invoke-Check 'App updates' {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            Add-Finding 'App updates' 'WARN' 'winget not found (common when running as SYSTEM)'
            return
        }
        if ($UpdateApps -and (Confirm-Action 'All winget-managed apps' 'Upgrade')) {
            & winget.exe upgrade --all --silent --accept-source-agreements --accept-package-agreements --disable-interactivity
            $status = if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' }
            Add-Finding 'App updates' $status "winget upgrade --all finished with exit code $LASTEXITCODE"
        }
        else {
            $out   = & winget.exe upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String
            $match = [regex]::Match($out, '(\d+) upgrades? available')
            if ($match.Success) {
                Add-Finding 'App updates' 'WARN' "$($match.Groups[1].Value) app upgrade(s) available (run with -UpdateApps)"
            }
            else {
                Add-Finding 'App updates' 'OK' 'No winget upgrades found'
            }
        }
    }
    if ($CleanTemp) {
        Invoke-Check 'Temp cleanup' {
            $cutoff = (Get-Date).AddDays(-$TempMaxAgeDays)
            $paths = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')) | Sort-Object -Unique
            $files = @(foreach ($p in $paths) {
                Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff }
            })
            if ($files.Count -eq 0) {
                Add-Finding 'Temp cleanup' 'OK' "Nothing older than $TempMaxAgeDays days"
                return
            }
            $totalMB = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
            if (-not (Confirm-Action "$($files.Count) temp files ($totalMB MB)" 'Delete')) { return }
            $freed = 0; $skipped = 0
            foreach ($f in $files) {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
                    $freed += $f.Length
                }
                catch {
                    $skipped++
                }
            }
            Add-Finding 'Temp cleanup' 'OK' ('Freed {0} MB; {1} file(s) skipped because they were in use' -f [math]::Round($freed / 1MB, 1), $skipped)
        }
    }
    if ($CleanComponentStore) {
        Invoke-Check 'Component store' {
            if (-not (Confirm-Action 'Component store (WinSxS)' 'Remove superseded components')) { return }
            & dism.exe /Online /Cleanup-Image /StartComponentCleanup
            $status = if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' }
            Add-Finding 'Component store' $status "DISM StartComponentCleanup exit code $LASTEXITCODE"
        }
    }

    if ($OptimizeDrives) {
        Invoke-Check 'Optimize drives' {
            $volumes = Get-Volume | Where-Object {
                $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystemType -in 'NTFS', 'ReFS', 'FAT32', 'exFAT'
            }
            foreach ($v in $volumes) {
                $letter = $v.DriveLetter
                $media = 'Unknown'
                try {
                    $diskNumber = (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber
                    $physical = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$diskNumber" }
                    if ($physical) { $media = "$($physical.MediaType)" }
                }
                catch { }
                $operation = switch ($media) {
                    'SSD'   { 'retrim' }
                    'HDD'   { 'defragment' }
                    default { 'default operation for its media type' }
                }
                if (-not (Confirm-Action "Volume $($letter): ($media)" "Optimize ($operation)")) { continue }
                Write-Host "Optimizing $($letter): ($media, $operation)..."
                try {
                    Optimize-Volume -DriveLetter $letter -ErrorAction Stop -WhatIf:$false -Confirm:$false
                    Add-Finding 'Optimize drives' 'OK' "$($letter): $media - $operation completed"
                }
                catch {
                    Add-Finding 'Optimize drives' 'WARN' "$($letter): $($_.Exception.Message)"
                }
            }
        }
    }

    if ($Repair) {
        Invoke-Check 'System repair' {
            if (-not (Confirm-Action 'Windows image and system files' 'DISM RestoreHealth, then SFC')) { return }
            Write-Host 'Running DISM /RestoreHealth (can take 10-30 minutes)...'
            & dism.exe /Online /Cleanup-Image /RestoreHealth
            if ($LASTEXITCODE -ne 0) {
                Add-Finding 'System repair' 'FAIL' "DISM failed (exit $LASTEXITCODE); SFC skipped. See $env:SystemRoot\Logs\DISM\dism.log"
                return
            }
            Write-Host 'Running SFC /scannow...'
            & sfc.exe /scannow
            Add-Finding 'System repair' 'INFO' "DISM succeeded; SFC exit code $LASTEXITCODE. Details in $env:SystemRoot\Logs\CBS\CBS.log"
        }
    }
    Invoke-Check 'Disk space' {
        $volumes = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.Size -gt 0 }
        foreach ($v in $volumes) {
            $pct    = [math]::Round($v.SizeRemaining / $v.Size * 100, 1)
            $freeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
            $status = if ($pct -lt $MinFreePercent) { 'WARN' } else { 'OK' }
            Add-Finding "Disk $($v.DriveLetter):" $status "$freeGB GB free ($pct%)"
        }
    }
    Invoke-Check 'Disk health' {
        foreach ($d in Get-PhysicalDisk) {
            $rel   = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            $notes = @("health: $($d.HealthStatus)")
            if ($rel -and $null -ne $rel.Wear)        { $notes += "wear: $($rel.Wear)%" }
            if ($rel -and $rel.Temperature)           { $notes += "temp: $($rel.Temperature) C" }
            if ($rel -and $rel.ReadErrorsUncorrected) { $notes += "uncorrected read errors: $($rel.ReadErrorsUncorrected)" }

            $status = if ($d.HealthStatus -ne 'Healthy' -or ($rel -and $rel.ReadErrorsUncorrected -gt 0)) { 'FAIL' }
                      elseif ($rel -and $rel.Wear -ge 80) { 'WARN' }
                      else { 'OK' }
            Add-Finding 'Disk health' $status "$($d.FriendlyName) [$($d.MediaType)] - $($notes -join ', ')"
        }
    }
    Invoke-Check 'Optimize schedule' {
        $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
        if (-not $task) {
            Add-Finding 'Optimize schedule' 'WARN' 'ScheduledDefrag task not found - drives are not optimized automatically'
            return
        }
        if ($task.State -eq 'Disabled') {
            Add-Finding 'Optimize schedule' 'WARN' 'Scheduled drive optimization is disabled (run with -OptimizeDrives, or re-enable it in "Defragment and Optimize Drives")'
            return
        }
        $info = $task | Get-ScheduledTaskInfo
        if (-not $info.LastRunTime -or $info.LastRunTime -lt [datetime]'2000-01-01') {
            Add-Finding 'Optimize schedule' 'WARN' 'Enabled, but has never run'
            return
        }
        $days = [math]::Round(((Get-Date) - $info.LastRunTime).TotalDays)
        $code = '0x{0:X}' -f $info.LastTaskResult
        if ($info.LastTaskResult -eq 0x41301) {
            Add-Finding 'Optimize schedule' 'INFO' 'Enabled; currently running'
        }
        elseif ($info.LastTaskResult -ne 0) {
            Add-Finding 'Optimize schedule' 'WARN' "Enabled; last run $days day(s) ago ended with $code (often it was only interrupted because the PC stopped being idle)"
        }
        elseif ($days -gt $MaxDaysSinceOptimize) {
            Add-Finding 'Optimize schedule' 'WARN' "Enabled, but last ran $days days ago"
        }
        else {
            Add-Finding 'Optimize schedule' 'OK' "Enabled; last ran $days day(s) ago and succeeded"
        }
    }
    Invoke-Check 'BitLocker' {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($bl.ProtectionStatus -ne 'On') {
            Add-Finding 'BitLocker' 'WARN' "$env:SystemDrive is not protected (volume status: $($bl.VolumeStatus))"
        }
        elseif (-not ($bl.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })) {
            Add-Finding 'BitLocker' 'WARN' 'Protected, but there is no recovery password protector'
        }
        else {
            Add-Finding 'BitLocker' 'OK' 'Protected; recovery password exists (make sure it is stored off this machine)'
        }
    }
    Invoke-Check 'Secure Boot' {
        $sb = $null
        try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { }
        if ($sb -eq $true)      { Add-Finding 'Secure Boot' 'OK' 'Enabled' }
        elseif ($sb -eq $false) { Add-Finding 'Secure Boot' 'WARN' 'UEFI system, but Secure Boot is disabled' }
        else                    { Add-Finding 'Secure Boot' 'WARN' 'Not supported (legacy BIOS / CSM boot?)' }
    }
    Invoke-Check 'TPM' {
        $tpm = Get-Tpm
        if ($tpm.TpmPresent -and $tpm.TpmReady) { Add-Finding 'TPM' 'OK' 'Present and ready' }
        elseif ($tpm.TpmPresent)                { Add-Finding 'TPM' 'WARN' 'Present but not ready' }
        else                                    { Add-Finding 'TPM' 'WARN' 'Not detected (or disabled in firmware)' }
    }
    if ($BackupPath) {
        Invoke-Check 'Backup' {
            if (-not (Test-Path -LiteralPath $BackupPath)) {
                Add-Finding 'Backup' 'FAIL' "Backup location not reachable: $BackupPath"
                return
            }
            $newest = Get-ChildItem -LiteralPath $BackupPath -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $newest) {
                Add-Finding 'Backup' 'FAIL' "No files found in $BackupPath"
                return
            }
            $age = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalDays, 1)
            $status = if ($age -gt $BackupMaxAgeDays) { 'FAIL' } else { 'OK' }
            Add-Finding 'Backup' $status "Newest file is $age day(s) old ($($newest.Name))"
        }
    }
    else {
        Add-Finding 'Backup' 'INFO' 'Not checked (pass -BackupPath to verify backups are recent)'
    }
    Invoke-Check 'Event log' {
        $since = (Get-Date).AddDays(-$EventLookbackDays)
        $queries = [ordered]@{
            'Unexpected shutdowns (Kernel-Power 41)' = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }
            'Hardware errors (WHEA)'                 = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 1, 2, 3; StartTime = $since }
            'Disk errors'                            = @{ LogName = 'System'; ProviderName = 'disk'; Level = 1, 2, 3; StartTime = $since }
        }
        $found = $false
        foreach ($label in $queries.Keys) {
            $events = @(Get-WinEvent -FilterHashtable $queries[$label] -ErrorAction SilentlyContinue)
            if ($events.Count -gt 0) {
                $found = $true
                Add-Finding 'Event log' 'WARN' "$label in last $EventLookbackDays days: $($events.Count) (most recent $($events[0].TimeCreated))"
            }
        }
        $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -ErrorAction SilentlyContinue)
        if ($crashes.Count -gt 0) {
            $found = $true
            $top = $crashes | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending |
                Select-Object -First 3 | ForEach-Object { "$($_.Name) x$($_.Count)" }
            Add-Finding 'Event log' 'INFO' "Application crashes: $($crashes.Count) (top: $($top -join ', '))"
        }
        if (-not $found) {
            Add-Finding 'Event log' 'OK' "No shutdowns, hardware/disk errors or app crashes in last $EventLookbackDays days"
        }
    }
    Invoke-Check 'Startup items' {
        $names = @(Get-CimInstance Win32_StartupCommand | Select-Object -ExpandProperty Name -Unique)
        Add-Finding 'Startup items' 'INFO' "$($names.Count) registered: $($names -join ', ')"
    }
    Invoke-Check 'Pending restart' {
        $reasons = @()
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Windows servicing' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
        if ($script:UpdateRebootRequired) { $reasons += 'updates installed this run' }
        if ($reasons) { Add-Finding 'Pending restart' 'WARN' "Restart needed: $($reasons -join ', ')" }
        else          { Add-Finding 'Pending restart' 'OK' 'No restart pending' }
    }
}
finally {
    if ($script:Findings.Count -gt 0) {
        $order = @{ FAIL = 0; WARN = 1; INFO = 2; OK = 3 }
        Write-Host "`n=================== Summary ===================" -ForegroundColor Cyan
        $script:Findings | Sort-Object { $order[$_.Status] } |
            Format-Table Status, Area, Detail -AutoSize -Wrap | Out-Host
        $csv = Join-Path $LogDir "report-$stamp.csv"
        $script:Findings | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -WhatIf:$false
        Write-Host "Report saved to $csv"
    }
    Get-ChildItem -Path $LogDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $WhatIfPreference = $false
    Stop-Transcript | Out-Null
}
$statuses = @($script:Findings | ForEach-Object { $_.Status })
if ($statuses -contains 'FAIL')     { exit 2 }
elseif ($statuses -contains 'WARN') { exit 1 }
else                                { exit 0 }
