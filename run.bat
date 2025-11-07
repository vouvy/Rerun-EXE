@echo off
setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION
set "PY_VERSION=3.11.8"
set "REQ_MODULES="
set "TOOL_NAME=Rerun EXE"
set "SCRIPT_PATH=%~dp0rerun_exe.py"
set "CONFIG_PATH=%~dp0rerun_exe_config.json"
set "ARCH=amd64"
set "INSTALLER=python-%PY_VERSION%-%ARCH%.exe"
set "PY_URL=https://www.python.org/ftp/python/%PY_VERSION%/%INSTALLER%"
set "DEBUG_FLAG=%DEBUG%"
set "FORCE_REINSTALL=%FORCE_PYTHON%"  rem set FORCE_PYTHON=1 to force reinstall
set "RAW_ARGS=%*"
set "SCRIPT_ARGS="
set "NO_PAUSE="
if defined TRACE echo on
for /f "tokens=1-3 delims=." %%a in ("%PY_VERSION%") do (
    set "PY_MAJOR=%%a"
    set "PY_MINOR=%%b"
    set "PY_PATCH=%%c"
)
if not defined PY_MAJOR set PY_MAJOR=3
if not defined PY_MINOR set PY_MINOR=11
set "PY_MM=%PY_MAJOR%%PY_MINOR%"
if not "%~1"=="" goto :args_loop
goto :args_done
:args_loop
if "%~1"=="" goto :args_done
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else (
    if defined SCRIPT_ARGS (
        set "SCRIPT_ARGS=%SCRIPT_ARGS% %~1"
    ) else (
        set "SCRIPT_ARGS=%~1"
    )
)
shift
goto :args_loop
:args_done
if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] Target Python: %PY_VERSION% (major=%PY_MAJOR% minor=%PY_MINOR% mm=%PY_MM%)
if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] Raw args: %RAW_ARGS%
echo [LAUNCH] %TOOL_NAME% bootstrap starting...
call :detect_python
if errorlevel 1 (
    echo [INFO] Attempting installation of Python %PY_VERSION% ...
    call :install_python || goto :fatal_python
    call :detect_python || goto :fatal_python
)
set "USE_PY_LAUNCHER="
set "PY_EXEC="
echo %FOUND_PYTHON% | findstr /i "py.exe" >nul
if not errorlevel 1 (
    set "USE_PY_LAUNCHER=1"
) else (
    set "PY_EXEC=%FOUND_PYTHON%"
)
if not defined PY_EXEC (
    set "PY_EXEC=python"
)
if /i "%DEBUG_FLAG%"=="1" (
  if defined USE_PY_LAUNCHER (
      echo [DEBUG] Using interpreter: py -%PY_MAJOR%.%PY_MINOR%
  ) else (
      echo [DEBUG] Using interpreter: %PY_EXEC%
  )
)
call :runpy -m ensurepip --default-pip >nul 2>nul
call :runpy -m pip --version >nul 2>nul || call :runpy -m ensurepip --upgrade >nul 2>nul
if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] Pip ready.
if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] Raw REQ_MODULES="%REQ_MODULES%"
if defined SKIP_MODULE_SYNC goto :modules_skip
if "%REQ_MODULES%"=="" goto :modules_none
call :sync_required_modules
goto :modules_done
:modules_skip
echo [SKIP] Skipping module installation (SKIP_MODULE_SYNC=1)
goto :modules_done
:modules_none
if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] No additional Python packages required.
:modules_done
if exist "%SCRIPT_PATH%" (
    if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] Supervisor script: "%SCRIPT_PATH%"
) else (
    echo [ERROR] Unable to locate rerun_exe.py at "%SCRIPT_PATH%"
    set "SCRIPT_EXIT=1"
    goto :end
)
if exist "%CONFIG_PATH%" (
    if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] Configuration file: "%CONFIG_PATH%"
) else (
    echo [INFO] Configuration file will be created automatically on first launch: "%CONFIG_PATH%"
)
echo [RUN] Launching %TOOL_NAME% console...
if defined SCRIPT_ARGS (
    call :runpy "%SCRIPT_PATH%" %SCRIPT_ARGS%
) else (
    call :runpy "%SCRIPT_PATH%"
)
set "SCRIPT_EXIT=%errorlevel%"
goto :end
:detect_python
if /i "%FORCE_REINSTALL%"=="1" (
    if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] FORCE_PYTHON=1 ignore existing
    exit /b 1
)
set "FOUND_PYTHON="
if exist "%LocalAppData%\Programs\Python\Python%PY_MM%\python.exe" set "FOUND_PYTHON=%LocalAppData%\Programs\Python\Python%PY_MM%\python.exe" & goto :dp_ver
if exist "%ProgramFiles%\Python%PY_MM%\python.exe" set "FOUND_PYTHON=%ProgramFiles%\Python%PY_MM%\python.exe" & goto :dp_ver
for /f "delims=" %%P in ('where python 2^>nul') do (
    for /f "delims=" %%V in ('"%%~P" -c "import sys;print(f'{sys.version_info[0]}.{sys.version_info[1]}')" 2^>nul') do if "%%V"=="%PY_MAJOR%.%PY_MINOR%" (set "FOUND_PYTHON=%%~P" & goto :dp_ver)
)
for /f "delims=" %%P in ('where py 2^>nul') do (
    "%%~P" -%PY_MAJOR%.%PY_MINOR% -c "import sys" >nul 2>nul && set "FOUND_PYTHON=%%~P" & goto :dp_ok
)
goto :dp_fail
:dp_ver
for /f "delims=" %%V in ('"%FOUND_PYTHON%" -c "import sys;print(f'{sys.version_info[0]}.{sys.version_info[1]}')" 2^>nul') do if not "%%V"=="%PY_MAJOR%.%PY_MINOR%" set "FOUND_PYTHON="
if not defined FOUND_PYTHON goto :dp_fail
:dp_ok
if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] locate: !FOUND_PYTHON!
exit /b 0
:dp_fail
exit /b 1
:install_python
if exist "%INSTALLER%" del "%INSTALLER%" >nul 2>nul
echo [INFO] Downloading installer: %INSTALLER%
curl -L -o "%INSTALLER%" "%PY_URL%" 2>nul || (
    powershell -Command "Invoke-WebRequest -Uri '%PY_URL%' -OutFile '%INSTALLER%'" || (
        echo [ERROR] Download failed.
        exit /b 1
    )
)
if not exist "%INSTALLER%" (
    echo [ERROR] Installer file missing after download.
    exit /b 1
)
echo [INFO] Installing Python silently...
"%INSTALLER%" /quiet InstallAllUsers=1 PrependPath=1 Include_launcher=1 >nul 2>nul
call :wait_python 25 && goto :inst_ok
echo [INFO] All-user silent install not detected. Trying per-user...
"%INSTALLER%" /quiet InstallAllUsers=0 PrependPath=1 Include_launcher=1 >nul 2>nul
call :wait_python 20 && goto :inst_ok
echo [ERROR] Python install attempts failed.
del "%INSTALLER%" >nul 2>nul
exit /b 1
:inst_ok
del "%INSTALLER%" >nul 2>nul
echo [OK] Python installed.
exit /b 0
:wait_python
set "WT=%~1"
if not defined WT set WT=20
for /l %%I in (1,1,%WT%) do (
    if exist "%LocalAppData%\Programs\Python\Python%PY_MM%\python.exe" (
        "%LocalAppData%\Programs\Python\Python%PY_MM%\python.exe" -c "import sys" >nul 2>nul && exit /b 0
    )
    if exist "%ProgramFiles%\Python%PY_MM%\python.exe" (
        "%ProgramFiles%\Python%PY_MM%\python.exe" -c "import sys" >nul 2>nul && exit /b 0
    )
    for /f "delims=" %%P in ('where python 2^>nul') do (
        "%%~P" -c "import sys" >nul 2>nul && exit /b 0
    )
    for /f "delims=" %%P in ('where py 2^>nul') do (
        "%%~P" -%PY_MAJOR%.%PY_MINOR% -c "import sys" >nul 2>nul && exit /b 0
    )
    if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] waiting python (%%I/%WT%)
    timeout /t 1 >nul
)
exit /b 1
:sync_required_modules
set "UPGRADE_FLAG=%UPGRADE_MODULES%"
set "MISSING_LIST="
for %%M in (!REQ_MODULES!) do (
    call :runpy -c "import %%M" >nul 2>nul || set "MISSING_LIST=!MISSING_LIST! %%M"
)
if defined PIP_TARGET echo [WARN] PIP_TARGET is set to '%PIP_TARGET%' which may place packages in this folder.
if defined PIP_PREFIX echo [WARN] PIP_PREFIX is set to '%PIP_PREFIX%' (affects install location).
if defined UPGRADE_FLAG (
    echo [INFO] Upgrading modules: !REQ_MODULES!
    call :runpy -m pip install -U !REQ_MODULES!
) else (
    if defined MISSING_LIST (
        echo [INFO] Installing missing modules: !MISSING_LIST:~1!
        call :runpy -m pip install !MISSING_LIST!
    ) else (
        echo [CHECK] All required modules already present.
    )
)
for %%M in (!REQ_MODULES!) do (
    call :runpy -c "import %%M" >nul 2>nul || echo [WARN] Module %%M import verification failed.
)
if /i "%DEBUG_FLAG%"=="1" (
    echo [DEBUG] Final module list versions:
    for %%M in (!REQ_MODULES!) do call :runpy -m pip show %%M 2>nul | find /i "Version:" || echo    %%M: (missing)
)
exit /b 0
:runpy
if defined USE_PY_LAUNCHER (
    py -%PY_MAJOR%.%PY_MINOR% %*
) else (
    "%PY_EXEC%" %*
)
exit /b %errorlevel%
:fatal_python
echo [FATAL] Could not set up Python environment.
set "SCRIPT_EXIT=1"
goto :finalize
:end
if not defined SCRIPT_EXIT set "SCRIPT_EXIT=%errorlevel%"
echo [DONE] %TOOL_NAME% finished.
goto :finalize
:finalize
if not defined SCRIPT_EXIT set "SCRIPT_EXIT=0"
if /i "%DEBUG_FLAG%"=="1" echo [DEBUG] Exit code: %SCRIPT_EXIT%
if not defined NO_PAUSE pause
endlocal & exit /b %SCRIPT_EXIT%