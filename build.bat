@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=%~dp0"
set "BDS_VERSION="
set "RUN_TESTS="
:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="--bds" (set "BDS_VERSION=%~2" & shift & shift & goto parse_args)
if /I "%~1"=="--tests" (set "RUN_TESTS=1" & shift & goto parse_args)
if /I "%~1"=="--help" goto usage
echo Unknown argument: %~1 1>&2
goto usage_error
:usage
echo Usage: build.bat [--bds ^<version^>] [--tests]
echo   --bds    BDS version to use (e.g. 22.0). Default: newest installed with rsvars.bat
echo   --tests  also build and run tests\DelphiBackupRestoreTests.dpr
exit /b 0
:usage_error
exit /b 4
:args_done
set "RSVARS="
if not "%BDS_VERSION%"=="" (
  for /f "usebackq delims=" %%R in (`powershell -NoProfile -Command "$v='%BDS_VERSION%'; foreach($h in @('HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS\'+$v,'HKLM:\SOFTWARE\Embarcadero\BDS\'+$v)){if(Test-Path $h){$r=(Get-ItemProperty $h).RootDir;if($r){$f=Join-Path $r 'bin\rsvars.bat';if(Test-Path $f){$f;break}}}}"`) do set "RSVARS=%%R"
) else (
  for /f "usebackq delims=" %%R in (`powershell -NoProfile -Command "$b='HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS'; if(Test-Path $b){foreach($k in (Get-ChildItem $b | Sort-Object { [version]$_.PSChildName } -Descending)){ $r=(Get-ItemProperty $k.PSPath).RootDir; if($r){$f=Join-Path $r 'bin\rsvars.bat'; if(Test-Path $f){$f;break}}}}"`) do if not defined RSVARS set "RSVARS=%%R"
)
if not defined RSVARS (echo Could not locate rsvars.bat. 1>&2 & exit /b 2)
if not exist "%RSVARS%" (echo rsvars.bat not found: "%RSVARS%" 1>&2 & exit /b 2)
call "%RSVARS%"
if errorlevel 1 exit /b %errorlevel%

for /f "usebackq delims=" %%V in ("%ROOT%VERSION") do set "VERSION=%%V"
for /f "tokens=1-3 delims=." %%A in ("!VERSION!") do (set "MAJOR=%%A"&set "MINOR=%%B"&set "PATCH=%%C")
set "VER=!MAJOR!.!MINOR!.!PATCH!.0"
(
  echo 1 VERSIONINFO
  echo FILEVERSION !MAJOR!,!MINOR!,!PATCH!,0
  echo PRODUCTVERSION !MAJOR!,!MINOR!,!PATCH!,0
  echo FILEFLAGSMASK 0x3fL
  echo FILEFLAGS 0
  echo FILEOS 0x40004L
  echo FILETYPE 0x1L
  echo FILESUBTYPE 0
  echo BEGIN
  echo   BLOCK "StringFileInfo"
  echo   BEGIN
  echo     BLOCK "040904B0"
  echo     BEGIN
  echo       VALUE "FileVersion", "!VER!"
  echo       VALUE "ProductVersion", "!VER!"
  echo       VALUE "ProductName", "Delphi Backup Restore"
  echo     END
  echo   END
  echo   BLOCK "VarFileInfo"
  echo   BEGIN
  echo     VALUE "Translation", 0x0409, 1200
  echo   END
  echo END
) > "%ROOT%src\VersionInfo.rc"
if exist "%ROOT%src\DelphiBackupRestore.manifest" >> "%ROOT%src\VersionInfo.rc" echo 1 24 "DelphiBackupRestore.manifest"
if not exist "%ROOT%.build" mkdir "%ROOT%.build"
pushd "%ROOT%src"
if exist "DelphiBackupRestore.res" del "DelphiBackupRestore.res"
rem cgrc (RAD Studio 2010+) is preferred: brcc32 silently writes an empty .res when the
rem path contains a folder starting with a dot (e.g. .wc\<task> worktrees)
where cgrc >nul 2>nul
if errorlevel 1 (
  brcc32 -foDelphiBackupRestore.res VersionInfo.rc
) else (
  cgrc -c65001 VersionInfo.rc -foDelphiBackupRestore.res
)
if errorlevel 1 (popd & exit /b 2)
for %%F in ("DelphiBackupRestore.res") do set "RES_SIZE=%%~zF"
popd
if not defined RES_SIZE (echo Resource file was not created. 1>&2 & exit /b 2)
if %RES_SIZE% LSS 200 (echo Resource file is empty ^(%RES_SIZE% bytes^): version info/manifest missing. 1>&2 & exit /b 2)
if not exist "%ROOT%bin" mkdir "%ROOT%bin"
set "DCC_FLAGS=-B -Q -NSSystem;Winapi;Vcl;Vcl.Imaging;Data -R"%ROOT%src" -E"%ROOT%bin" -N0"%ROOT%.build" -U"%ROOT%src""
echo Building GUI executable...
dcc32 %DCC_FLAGS% "%ROOT%src\DelphiBackupRestore.dpr"
if errorlevel 1 exit /b 2
echo Building console executable...
dcc32 %DCC_FLAGS% "%ROOT%src\DelphiBackupRestoreCli.dpr"
if errorlevel 1 exit /b 2
if not defined RUN_TESTS exit /b 0
if not exist "%ROOT%tests\DelphiBackupRestoreTests.dpr" (echo tests\DelphiBackupRestoreTests.dpr not found 1>&2 & exit /b 2)
echo Building tests...
dcc32 %DCC_FLAGS% -U"%ROOT%tests" "%ROOT%tests\DelphiBackupRestoreTests.dpr"
if errorlevel 1 exit /b 2
echo Running tests...
"%ROOT%bin\DelphiBackupRestoreTests.exe" --exitbehavior:Continue
exit /b %errorlevel%
