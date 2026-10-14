@echo off
REM ===========================================================================
REM  RUN-MAINTENANCE.cmd  -  put this on the thumb drive.
REM  Contains NO password and NO secret. It just launches a detached PowerShell
REM  that fetches the script from GitHub into memory. Working dir is %TEMP%, so
REM  the drive is released the instant the window opens - safe to remove it then.
REM
REM  EDIT SCRIPTURL below to your raw GitHub URL if it ever changes.
REM ===========================================================================

set "SCRIPTURL=https://raw.githubusercontent.com/aidanlenahan/secdiagdrop/main/Invoke-PCMaintenance.ps1"

start "PC Maintenance" /D "%TEMP%" powershell -NoProfile -ExecutionPolicy Bypass -Command "try { & ([scriptblock]::Create((irm '%SCRIPTURL%'))) } catch { Write-Host $_.Exception.Message -ForegroundColor Red; Write-Host ''; Read-Host 'Press Enter to close' }"

exit
