@echo off
rem Smoke test: solve the RSoft example gauss.ind (BeamPROP, 2D, under a second) on the allowed CPUs only.
rem Keep this file ASCII-only: cmd.exe reads .bat files in the console code page, not UTF-8.
copy "%LABPC_RSOFT%\..\examples\BeamPROP\gauss.ind" . > nul
if not exist gauss.ind (
  echo rsoft: example gauss.ind not found
  exit /b 2
)
if defined LABPC_AFFINITY (
  start "" /wait /b /affinity %LABPC_AFFINITY% "%LABPC_RSOFT%\bsimw32.exe" -hide gauss.ind prefix=gauss wait=0
) else (
  start "" /wait /b "%LABPC_RSOFT%\bsimw32.exe" -hide gauss.ind prefix=gauss wait=0
)
if errorlevel 1 (
  type log.txt
  exit /b %errorlevel%
)
if exist gauss.dataindex (
  echo rsoft OK: BeamPROP gauss.ind solved
) else (
  type log.txt
  echo rsoft: no output
  exit /b 3
)
