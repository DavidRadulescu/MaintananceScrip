<#
.SYNOPSIS
    Windows health check and maintenance.

.DESCRIPTION
    Runs read-only health checks by default and prints a summary report.
    Anything that changes the system only runs when you pass its switch,
    and every change honours -WhatIf and -Confirm.

    Written for Windows PowerShell 5.1 (the one built into Windows), run as
    Administrator. Some cmdlets used here (Get-ComputerRestorePoint,
    Checkpoint-Computer) do not exist in PowerShell 7.

    A transcript and a CSV report are written to %ProgramData%\WinMaintenance.
    Output from native tools (DISM, SFC, winget) goes to the console and to
    their own logs rather than into the transcript.

    Exit codes: 0 = everything OK, 1 = warnings, 2 = failures.
    That makes it usable from Task Scheduler, an RMM tool or an Intune
    remediation script, which all key off the exit code.

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1
    Report only. Changes nothing.

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -CreateRestorePoint -UpdateDefender -UpdateApps -CleanTemp
    A typical weekly run.

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -InstallWindowsUpdates -CleanTemp -WhatIf
    Show what would be installed and deleted without doing it.

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -Repair
    DISM RestoreHealth followed by SFC, for when something is actually broken.

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -BackupPath 'D:\Backups' -BackupMaxAgeDays 3
    Also verify that the backup destination received new files recently.
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    # --- actions (all off by default) ---
    [switch]$CreateRestorePoint,
    [switch]$InstallWindowsUpdates,
    [switch]$UpdateDefender,
    [switch]$UpdateApps,
    [switch]$CleanTemp,
    [switch]$CleanComponentStore,
    [switch]$Repair,

    # --- thresholds and options ---
    [string]$BackupPath,
    [int]$BackupMaxAgeDays  = 7,
    [int]$TempMaxAgeDays    = 7,
    [int]$MinFreePercent    = 15,
    [int]$MaxUptimeDays     = 7,
    [int]$MaxDaysSinceWUInstall = 35,
    [int]$EventLookbackDays = 7,
    [int]$LogRetentionDays  = 60,
    [string]$LogDir         = (Join-Path $env:ProgramData 'WinMaintenance')
)

# =============================================================== helpers ===

$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Cmdlet   = $PSCmdlet
$script:UpdateRebootRequired = $false

# Every check reports through this, so the summary, the CSV and the exit
# code all come from one list.
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

# Runs one check in isolation. If it throws, that is recorded and the run
# carries on, so one broken check never hides the results of the others.
function Invoke-Check {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        # e.g. BitLocker cmdlets on Windows Home: not a problem, just not applicable
        Add-Finding $Name 'INFO' "Not available on this system ($($_.Exception.CommandName))"
    }
    catch {
        Add-Finding $Name 'WARN' "Check could not run: $($_.Exception.Message)"
    }
}

# Gate for anything that changes the system. Going through ShouldProcess
# means -WhatIf and -Confirm also cover external tools (DISM, winget),
# not only PowerShell cmdlets that support them natively.
function Confirm-Action {
    param([string]$Target, [string]$Action)
    $script:Cmdlet.ShouldProcess($Target, $Action)
}

# ================================================================= setup ===

# -WhatIf:$false here because -WhatIf would otherwise also suppress our own
# logging, which is exactly when you want to see what would have happened.
New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $LogDir "maintenance-$stamp.log") -WhatIf:$false | Out-Null

try {
    Write-Host "Windows maintenance on $env:COMPUTERNAME, $(Get-Date)" -ForegroundColor Cyan
    if ($WhatIfPreference) { Write-Host 'WhatIf mode: no changes will be made.' -ForegroundColor Cyan }

    # ------------------------------------------------------- system state ---

    Invoke-Check 'OS version' {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $detail = '{0} {1} (build {2}.{3})' -f $os.Caption, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR
        # ProductType 1 = workstation. Builds below 22000 are Windows 10,
        # which is out of support without Extended Security Updates.
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
        # With Fast Startup, "Shut down" does not reset this. Only Restart does.
        if ($days -gt $MaxUptimeDays) {
            Add-Finding 'Uptime' 'WARN' "$days days since last real restart (Fast Startup shutdowns do not count)"
        }
        else {
            Add-Finding 'Uptime' 'OK' "$days days since last restart"
        }
    }

    # ---------------------------------------------------------- safety net ---
    # Runs before anything that changes the system, so there is something to
    # roll back to if an update or driver misbehaves.

    Invoke-Check 'Restore point' {
        if ($CreateRestorePoint -and (Confirm-Action 'System Restore' 'Create restore point')) {
            # Windows skips this silently if a restore point was created in the
            # last 24 hours (SystemRestorePointCreationFrequency). That is fine.
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

    # ------------------------------------------------------------ updates ---

    Invoke-Check 'Windows Update' {
        # When updates last installed successfully. A machine whose updates
        # have silently been failing for months shows up here.
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $lastOk = $au.Results.LastInstallationSuccessDate
        if ($lastOk) {
            $since = [math]::Round(((Get-Date) - [datetime]$lastOk).TotalDays)
            $status = if ($since -gt $MaxDaysSinceWUInstall) { 'WARN' } else { 'OK' }
            Add-Finding 'Windows Update' $status "Last successful install $since days ago"
        }

        # Uses the Windows Update Agent COM API directly, so no extra module
        # is needed. It respects WSUS/Intune policy if the machine is managed.
        # Type='Software' leaves out optional driver updates on purpose.
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

            # ResultCode: 2 = succeeded, 3 = succeeded with errors, 4 = failed, 5 = aborted
            $script:UpdateRebootRequired = $install.RebootRequired
            $status = if ($install.ResultCode -eq 2) { 'OK' } else { 'FAIL' }
            Add-Finding 'Windows Update' $status "Install result code $($install.ResultCode); restart required: $($install.RebootRequired)"
        }
    }

    Invoke-Check 'Defender' {
        $mp = Get-MpComputerStatus
        # If another antivirus is installed, Defender steps back into passive
        # mode. Its status is then not the one that matters.
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
        # winget is installed per user as an app package, so it is usually
        # missing when this runs as SYSTEM (e.g. from a scheduled task).
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            Add-Finding 'App updates' 'WARN' 'winget not found (common when running as SYSTEM)'
            return
        }

        if ($UpdateApps -and (Confirm-Action 'All winget-managed apps' 'Upgrade')) {
            & winget.exe upgrade --all --silent --accept-source-agreements --accept-package-agreements --disable-interactivity
            # Non-zero usually means at least one package failed (often an app
            # that was running, or one whose installer needs interaction).
            $status = if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' }
            Add-Finding 'App updates' $status "winget upgrade --all finished with exit code $LASTEXITCODE"
        }
        else {
            # Parsing winget's table is fragile (the text is localised), so
            # this only reads the "N upgrades available" line.
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

    # ------------------------------------------------------------ cleanup ---

    if ($CleanTemp) {
        Invoke-Check 'Temp cleanup' {
            $cutoff = (Get-Date).AddDays(-$TempMaxAgeDays)
            # Sort-Object -Unique is case-insensitive, so C:\WINDOWS\TEMP and
            # C:\Windows\Temp (the same folder when running as SYSTEM) collapse.
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
            # One confirmation for the whole batch instead of one per file.
            if (-not (Confirm-Action "$($files.Count) temp files ($totalMB MB)" 'Delete')) { return }

            $freed = 0; $skipped = 0
            foreach ($f in $files) {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
                    $freed += $f.Length
                }
                catch {
                    $skipped++   # in use by a running program: leave it alone
                }
            }
            Add-Finding 'Temp cleanup' 'OK' ('Freed {0} MB; {1} file(s) skipped because they were in use' -f [math]::Round($freed / 1MB, 1), $skipped)
        }
    }

    if ($CleanComponentStore) {
        Invoke-Check 'Component store' {
            if (-not (Confirm-Action 'Component store (WinSxS)' 'Remove superseded components')) { return }
            # Deliberately NOT /ResetBase: that would make every currently
            # installed update impossible to uninstall.
            & dism.exe /Online /Cleanup-Image /StartComponentCleanup
            $status = if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' }
            Add-Finding 'Component store' $status "DISM StartComponentCleanup exit code $LASTEXITCODE"
        }
    }

    # ------------------------------------------------------------- repair ---

    if ($Repair) {
        Invoke-Check 'System repair' {
            if (-not (Confirm-Action 'Windows image and system files' 'DISM RestoreHealth, then SFC')) { return }

            # Order matters: SFC repairs files from the component store, so the
            # store has to be healthy first or SFC "repairs" from a bad source.
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

    # ------------------------------------------------------------ storage ---
    # After cleanup, so the numbers reflect what was freed.

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

    # ----------------------------------------------------------- security ---

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

    # ------------------------------------------------------------- backup ---
    # Backup tools differ too much to query generically, but "did new files
    # land in the destination recently?" works for almost all of them.

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

    # -------------------------------------------------------- diagnostics ---

    Invoke-Check 'Event log' {
        $since = (Get-Date).AddDays(-$EventLookbackDays)
        $queries = [ordered]@{
            'Unexpected shutdowns (Kernel-Power 41)' = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }
            'Hardware errors (WHEA)'                 = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 1, 2, 3; StartTime = $since }
            'Disk errors'                            = @{ LogName = 'System'; ProviderName = 'disk'; Level = 1, 2, 3; StartTime = $since }
        }
        $found = $false
        foreach ($label in $queries.Keys) {
            # Get-WinEvent throws when nothing matches; SilentlyContinue turns that into "none".
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
        # Covers Run keys and Startup folders. Scheduled tasks and services are
        # not included, and items disabled in Task Manager may still be listed.
        $names = @(Get-CimInstance Win32_StartupCommand | Select-Object -ExpandProperty Name -Unique)
        Add-Finding 'Startup items' 'INFO' "$($names.Count) registered: $($names -join ', ')"
    }

    # Last, so it reflects anything installed during this run.
    # PendingFileRenameOperations is deliberately not checked: many installers
    # leave entries there, so it reports a pending restart almost constantly.
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

    # Housekeeping: remove this script's own logs past the retention period.
    Get-ChildItem -Path $LogDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Stop-Transcript | Out-Null
}

$statuses = @($script:Findings | ForEach-Object { $_.Status })
if ($statuses -contains 'FAIL')     { exit 2 }
elseif ($statuses -contains 'WARN') { exit 1 }
else                                { exit 0 }
