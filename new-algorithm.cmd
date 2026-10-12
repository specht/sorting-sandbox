@echo off
rem Windows: runs ./new-algorithm with the bash of Git for Windows.
setlocal
set "GITBASH="
for /f "delims=" %%g in ('where git 2^>nul') do (
  if not defined GITBASH if exist "%%~dpg..\bin\bash.exe" set "GITBASH=%%~dpg..\bin\bash.exe"
  if not defined GITBASH if exist "%%~dpg..\..\bin\bash.exe" set "GITBASH=%%~dpg..\..\bin\bash.exe"
)
if not defined GITBASH goto missing
"%GITBASH%" "%~dp0new-algorithm" %*
exit /b %errorlevel%
:missing
echo new-algorithm needs Git for Windows (https://git-scm.com/download/win). 1>&2
exit /b 1
