@echo off
SETLOCAL
pushd "%~dp0"

:: ------------------------------------------------------------------
:: Resolve Delphi root from dcc32 on PATH, then run rsvars.bat
:: ------------------------------------------------------------------
set DCC32_PATH=
for /f "tokens=*" %%i in ('where dcc32 2^>NUL') do (
    set DCC32_PATH=%%~dpi
    goto GotDcc32
)
:: Not on PATH? Search common locations
for /f "tokens=*" %%i in ('where /R "D:\" dcc32.exe 2^>NUL') do (
    set DCC32_PATH=%%~dpi
    goto GotDcc32
)
echo dcc32.exe not found. Run rsvars.bat from your Delphi\bin first.
goto FailedCompile

:GotDcc32
:: Go up one level from bin\ or bin64\ to get BDS root
set BDS=%DCC32_PATH%..
call "%BDS%\bin\rsvars.bat"

:: ------------------------------------------------------------------
:: Verify MSBuild is available
:: ------------------------------------------------------------------
where msbuild >NUL 2>NUL
if ERRORLEVEL 1 (
    echo MSBuild not found on PATH. Run VsDevCmd.bat or rsvars.bat first.
    goto FailedCompile
)

cd install

:: ------------------------------------------------------------------
:: Build JediIncCheck
:: ------------------------------------------------------------------
echo.
echo ===================================================================
echo Compiling JediIncCheck...
msbuild JediIncCheck.dproj /t:Make /p:Config=Release /p:Platform=Win32 /nologo /v:minimal
if ERRORLEVEL 1 goto FailedCompile

..\bin\JediIncCheck.exe
if ERRORLEVEL 1 goto OutdatedJediInc

:: ------------------------------------------------------------------
:: Build JediInstaller (dual-IDE support)
:: ------------------------------------------------------------------
echo.
echo ===================================================================
echo Compiling JediInstaller...
msbuild JediInstaller.dproj /t:Make /p:Config=Release /p:Platform=Win32 /nologo /v:minimal
if ERRORLEVEL 1 goto FailedCompile

if not exist ..\bin\JediInstaller.exe goto FailedCompile

:: ------------------------------------------------------------------
:: Launch
:: ------------------------------------------------------------------
echo.
echo ===================================================================
echo Launching JCL installer...
..\bin\JediInstaller.exe %*

if ERRORLEVEL 1 goto FailStart
goto FINI

:FailStart
echo.
echo Installer exited with error code %ERRORLEVEL%.
pause
goto FINI

:OutdatedJediInc
echo.
echo The "source\include\jedi\jedi.inc" include file is outdated.
echo You can download the newest version from https://github.com/project-jedi/jedi
echo.
pause
goto FINI

:FailedCompile
echo.
echo.
echo An error occured while compiling the installer. Installation aborted.
echo.
pause

:FINI
cd ..
SET DELPHIVERSION=
SET DCC32_PATH=
SET BDS=
popd
ENDLOCAL
