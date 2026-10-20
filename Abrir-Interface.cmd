@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -File "%~dp0Interface-CpfAD.ps1"
exit /b
