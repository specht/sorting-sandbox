@echo off
rem Starts the Sorting Sandbox on Windows (the same as ./run).
rem With a Dart SDK the app runs from source; without one, the precompiled app
rem for this version is downloaded once (see .github/workflows/host.yml).
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

rem SANDBOX_PRECOMPILED=1 tries the precompiled app even where Dart is installed.
set "DART_FOUND="
if not "%SANDBOX_PRECOMPILED%"=="1" where dart >nul 2>nul && set "DART_FOUND=1"
if defined DART_FOUND (
  call dart pub get || exit /b 1
  dart run tool\host.dart %*
  exit /b !errorlevel!
)

if not defined SANDBOX_RELEASES set "SANDBOX_RELEASES=specht/sorting-sandbox"
if not defined SANDBOX_DOWNLOADS set "SANDBOX_DOWNLOADS=https://github.com/!SANDBOX_RELEASES!/releases/download"
set "KEY="
for /f %%k in ('git ls-tree HEAD tool lib pubspec.yaml pubspec.lock 2^>nul ^| git hash-object --stdin 2^>nul') do set "KEY=%%k"
if not defined KEY (
  echo Cannot determine the app version: this folder must be a Git clone of the app. 1>&2
  echo Alternatively install the Dart SDK ^(https://dart.dev/get-dart^) and start run.cmd again. 1>&2
  exit /b 1
)
set "TAG=host-!KEY:~0,16!"
set "NAME=sandbox-host-windows-x64.exe"
set "FOLDER=runtime\host\!TAG!"
set "BINARY=!FOLDER!\!NAME!"

if not exist "!BINARY!" (
  set "URL=!SANDBOX_DOWNLOADS!/!TAG!/!NAME!"
  echo No Dart SDK found. Downloading the app for this computer...
  if not exist "!FOLDER!" mkdir "!FOLDER!"
  curl.exe -fL --progress-bar -o "!BINARY!.part" "!URL!"
  if errorlevel 1 (
    del /q "!BINARY!.part" 2>nul
    echo Download failed: !URL! 1>&2
    echo GitHub builds the app a few minutes after each change of the app; try again later. 1>&2
    echo Alternatively install the Dart SDK ^(https://dart.dev/get-dart^) and start run.cmd again. 1>&2
    exit /b 1
  )
  move /y "!BINARY!.part" "!BINARY!" >nul
  rem Older versions of the app are no longer needed.
  for /d %%d in (runtime\host\host-*) do if /i not "%%~nxd"=="!TAG!" rd /s /q "%%d"
)
"!BINARY!" %*
exit /b !errorlevel!
