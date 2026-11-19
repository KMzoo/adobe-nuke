@echo off
rem Double-click launcher for adobe-nuke.ps1 (keep both files in the same folder).
rem Windows opens .ps1 files in Notepad on double-click and blocks downloaded scripts,
rem so this starts PowerShell with the execution policy bypassed for this one run.
rem Administrator rights are requested automatically. Arguments are passed through:
rem   adobe-nuke.cmd -DryRun
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0adobe-nuke.ps1" %*
