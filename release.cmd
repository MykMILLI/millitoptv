@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0tools\release.ps1" %*
exit /b %ERRORLEVEL%
