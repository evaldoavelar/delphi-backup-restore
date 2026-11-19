@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=%~dp0"
set "BDS_VERSION="
if /I "%~1"=="--bds" set "BDS_VERSION=%~2"
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
brcc32 -foDelphiBackupRestore.res VersionInfo.rc
if errorlevel 1 (popd & exit /b %errorlevel%)
popd
if not exist "%ROOT%src\DelphiBackupRestore.dpr" (
  echo rsvars.bat found and brcc32 compiled src\VersionInfo.rc.
  echo Waiting for src\DelphiBackupRestore.dpr before compiling the application.
  exit /b 0
)
if not exist "%ROOT%bin" mkdir "%ROOT%bin"
dcc32 -B -Q -NSSystem;Winapi;Vcl;Vcl.Imaging -R"%ROOT%src" -E"%ROOT%bin" -N0"%ROOT%.build" "%ROOT%src\DelphiBackupRestore.dpr"
if errorlevel 1 exit /b %errorlevel%
if /I "%~1"=="--tests" (
  dcc32 -B -Q -NSSystem;Winapi;Vcl;Vcl.Imaging -R"%ROOT%src" -E"%ROOT%bin" -N0"%ROOT%.build" "%ROOT%tests\DelphiBackupRestoreTests.dpr"
  if errorlevel 1 exit /b %errorlevel%
  "%ROOT%bin\DelphiBackupRestoreTests.exe"
  exit /b %errorlevel%
)
exit /b 0
