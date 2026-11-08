# Windows Maintenance Script

`Invoke-WindowsMaintenance.ps1` is a PowerShell script that checks the health of a Windows machine and can run common maintenance tasks.

By default it **only reports and changes nothing**. Each maintenance action runs only when you pass its switch, and every action supports `-WhatIf` (show what would happen) and `-Confirm` (ask before each action).

## Requirements

- Windows 10 or 11
- **Windows PowerShell 5.1** (`powershell.exe`, built into Windows). PowerShell 7 (`pwsh`) is not supported because it doesn't have the restore-point cmdlets.
- An **elevated** PowerShell window (right-click → *Run as administrator*)
- `winget` for app updates (built into Windows 11; on Windows 10, install *App Installer* from the Microsoft Store)

## Getting started

Download or clone the repository, open an elevated PowerShell window, and go to the folder:

```powershell
git clone https://github.com/DavidRadulescu/MaintananceScrip.git
cd MaintananceScrip
```

If you downloaded the file through a browser, Windows marks it as coming from the internet and may refuse to run it. Remove that mark once:

```powershell
Unblock-File .\Invoke-WindowsMaintenance.ps1
```

## Running it

### Option 1: from any shell (recommended)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-WindowsMaintenance.ps1
```

**Script switches go at the end, after the script path.** Anything before `-File` is read by `powershell.exe` itself, not by the script:

```powershell
# Correct
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-WindowsMaintenance.ps1 -UpdateApps

# Wrong: -UpdateApps is taken as the value of -ExecutionPolicy and the script never runs
powershell.exe -NoProfile -ExecutionPolicy -UpdateApps Bypass -File .\Invoke-WindowsMaintenance.ps1
```

`-ExecutionPolicy Bypass` applies only to that one process. It doesn't change the machine's execution policy.

### Option 2: from an existing Windows PowerShell 5.1 window

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Invoke-WindowsMaintenance.ps1
```

`-Scope Process` means the change lasts only until you close the window. Check that you're in 5.1 with `$PSVersionTable.PSVersion`.

## Common commands

All of these are written for Option 2. For Option 1, put the same switches after the script path.

```powershell
# Report only: changes nothing
.\Invoke-WindowsMaintenance.ps1

# Typical weekly run
.\Invoke-WindowsMaintenance.ps1 -CreateRestorePoint -UpdateDefender -UpdateApps -CleanTemp

# Install pending Windows updates
.\Invoke-WindowsMaintenance.ps1 -CreateRestorePoint -InstallWindowsUpdates

# Dry run: show what would be installed and deleted without doing it
.\Invoke-WindowsMaintenance.ps1 -InstallWindowsUpdates -UpdateApps -CleanTemp -WhatIf

# Ask before each action
.\Invoke-WindowsMaintenance.ps1 -UpdateApps -CleanTemp -Confirm

# Repair system files when something is actually broken (DISM, then SFC; 10-30 minutes)
.\Invoke-WindowsMaintenance.ps1 -Repair

# Also check that backups are recent
.\Invoke-WindowsMaintenance.ps1 -BackupPath 'D:\Backups' -BackupMaxAgeDays 3
```

## Switches

### Actions (all off by default)

| Switch | What it does |
|---|---|
| `-CreateRestorePoint` | Creates a System Restore point before anything else runs |
| `-InstallWindowsUpdates` | Downloads and installs pending Windows updates (drivers excluded) |
| `-UpdateDefender` | Updates Microsoft Defender security intelligence |
| `-UpdateApps` | Runs `winget upgrade --all` silently |
| `-CleanTemp` | Deletes temp files older than `-TempMaxAgeDays` from the user and Windows temp folders |
| `-CleanComponentStore` | Runs `DISM /StartComponentCleanup` (without `/ResetBase`, so installed updates stay uninstallable) |
| `-Repair` | Runs `DISM /RestoreHealth`, then `sfc /scannow` |

### Options

| Parameter | Default | Meaning |
|---|---|---|
| `-BackupPath` | *(none)* | Folder to check for recent backup files |
| `-BackupMaxAgeDays` | 7 | Newest backup file older than this → FAIL |
| `-TempMaxAgeDays` | 7 | Only temp files older than this are deleted |
| `-MinFreePercent` | 15 | Drives with less free space → WARN |
| `-MaxUptimeDays` | 7 | Longer since the last restart → WARN |
| `-MaxDaysSinceWUInstall` | 35 | Longer since the last successful Windows Update install → WARN |
| `-EventLookbackDays` | 7 | How far back to look in the event logs |
| `-LogRetentionDays` | 60 | The script's own logs older than this are deleted |
| `-LogDir` | `%ProgramData%\WinMaintenance` | Where logs and reports are written |

## What it checks

- **System:** OS version and Windows 10 end-of-support warning, days since the last real restart
- **Updates:** pending Windows updates and the date of the last successful install, Defender status and signature age, available winget app upgrades
- **Storage:** free space on each drive, physical disk health, SSD wear, uncorrected read errors
- **Security:** BitLocker and recovery key, Secure Boot, TPM
- **Backups:** age of the newest file at `-BackupPath`
- **Diagnostics:** unexpected shutdowns, hardware (WHEA) and disk errors, most frequently crashing apps, startup items, pending restart

## Output

Each check prints one line with a status: `OK`, `INFO`, `WARN` or `FAIL`. A summary table, sorted with the worst results first, is printed at the end.

Each run writes two files to `%ProgramData%\WinMaintenance`:

- `maintenance-<timestamp>.log`: transcript of the run
- `report-<timestamp>.csv`: the results as a table

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Everything OK |
| 1 | At least one warning |
| 2 | At least one failure |

Task Scheduler, RMM tools and Intune remediation scripts can act on these codes.

## Running it on a schedule

Example: a weekly scheduled task, Sundays at 10:00, running as SYSTEM with full privileges. Run this in an elevated window:

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Invoke-WindowsMaintenance.ps1" -CreateRestorePoint -UpdateDefender -CleanTemp'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 10am
Register-ScheduledTask -TaskName 'Windows Maintenance' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest
```

Change `C:\Scripts\` to wherever you keep the script. Two things behave differently when the script runs as SYSTEM:

- **winget** is installed per user, so it's usually not found. Leave out `-UpdateApps`, or run the task as your own admin account instead.
- **A network `-BackupPath`** is only reachable if the computer account has access to that share.

## Notes

- **The script never restarts the machine.** It reports when a restart is needed.
- **Close apps before `-UpdateApps`.** An installer usually can't replace files a running program has open.
- **"Installer hash does not match"** from winget means the downloaded installer isn't the file the winget catalog expects, usually because the vendor replaced it at the same URL. winget skips that package and continues. Run `winget source update` and try again in a day or two, or update that app through its own updater.
- **The Windows Update step doesn't work over remote PowerShell** (`Enter-PSSession`). Run it locally or as a scheduled task.
