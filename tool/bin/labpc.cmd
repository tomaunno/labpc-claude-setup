@echo off
rem labpc: run Lumerical / Zemax jobs on the lab Windows machines (the tool itself is ..\labpc.ps1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\labpc.ps1" %*
