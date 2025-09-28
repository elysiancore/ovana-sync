@echo off
REM Ovana build.bat - compila Sync (PyInstaller), GUI (aw-qt) y opcionalmente server Rust.
REM Requiere: Python 3.11+, pip, PyInstaller, (opcional) Rust/cargo, Inno Setup (ISCC en PATH).
REM Uso:
REM   build.bat                (omitir server, solo Sync+GUI)
REM   build.bat rust           (compila server rust si hay src\ovanaw-server-rust)
REM   build.bat python         (no compila rust; debes colocar aw-server-py.exe manualmente)
REM   build.bat skip           (igual a default; omite server)
REM   build.bat rust iscc      (también compila el instalador si ISCC está en PATH)

setlocal ENABLEDELAYEDEXPANSION
set ROOT=C:\ovana-agent
set SRC=%ROOT%\src
set DIST=%ROOT%\build\dist
set CFG=%ROOT%\build\config
set BIN_SERVER=%DIST%\server
set BIN_SYNC=%DIST%\sync
set BIN_GUI=%DIST%\gui
set ICON=%ROOT%\branding\icons\ovana.ico

set SERVER_MODE=%1%
set DO_ISCC=%2%

if "%SERVER_MODE%"=="" set SERVER_MODE=skip

echo [INFO] Creando carpetas destino...
mkdir "%BIN_SERVER%" 2>nul
mkdir "%BIN_SYNC%" 2>nul
mkdir "%BIN_GUI%" 2>nul
mkdir "%CFG%" 2>nul

REM 1) Server opcional (Rust)
if /I "%SERVER_MODE%"=="rust" (
  if exist "%SRC%\ovanaw-server-rust" (
    where cargo >nul 2>&1
    if errorlevel 1 (
      echo [WARN] cargo no encontrado. Se omite build de server Rust.
    ) else (
      echo [INFO] Compilando server (Rust)...
      pushd "%SRC%\ovanaw-server-rust"
      cargo build --release || goto :fail
      copy /Y "target\release\aw-server.exe" "%BIN_SERVER%\aw-server.exe" || goto :fail
      popd
    )
  ) else (
    echo [WARN] No existe %SRC%\ovanaw-server-rust. Omitiendo server Rust.
  )
) else if /I "%SERVER_MODE%"=="python" (
  echo [WARN] Modo server=python: coloca tu aw-server-py.exe manualmente en %BIN_SERVER%.
) else (
  echo [INFO] Server omitido (skip). Asegúrate de tener aw-server.exe o aw-server-py.exe en %BIN_SERVER% si lo necesitas.
)

REM 2) Sync (PyInstaller)
if not exist "%SRC%\ovana-sync" (
  echo [ERROR] No existe %SRC%\ovana-sync
  goto :fail
)
echo [INFO] Construyendo ovana-sync...
pushd "%SRC%\ovana-sync"
python -m venv .venv || goto :fail
".venv\Scripts\python.exe" -m pip install --upgrade pip -r requirements.txt pyinstaller || goto :fail
".venv\Scripts\pyinstaller.exe" --noconfirm --onefile --name ovana-sync sync.py || goto :fail
copy /Y "dist\ovana-sync.exe" "%BIN_SYNC%\ovana-sync.exe" || goto :fail
popd

REM 3) GUI (PyInstaller)
if not exist "%SRC%\ovanaw-qt" (
  echo [ERROR] No existe %SRC%\ovanaw-qt
  goto :fail
)
echo [INFO] Construyendo ovana-agent (GUI)...
pushd "%SRC%\ovanaw-qt"
python -m venv .venv || goto :fail
".venv\Scripts\python.exe" -m pip install --upgrade pip -r requirements.txt pyinstaller || goto :fail
set PYI=pyinstaller --noconfirm --onefile --windowed --name ovana-agent -m aw_qt
if exist "%ICON%" (
  set PYI=%PYI% --icon "%ICON%"
) else (
  echo [WARN] Icono %ICON% no existe; se prosigue sin --icon
)
".venv\Scripts\%PYI%" || goto :fail
copy /Y "dist\ovana-agent.exe" "%BIN_GUI%\ovana-agent.exe" || goto :fail
popd

REM 4) Config base (si no existe)
if not exist "%CFG%\config.toml" (
  echo [INFO] Creando config.toml base (remote_url vacio)
  > "%CFG%\config.toml" echo [server]
  >>"%CFG%\config.toml" echo remote_url = ""
  >>"%CFG%\config.toml" echo api_token  = ""
  >>"%CFG%\config.toml" echo.
  >>"%CFG%\config.toml" echo [sync]
  >>"%CFG%\config.toml" echo interval     = 60
  >>"%CFG%\config.toml" echo batch_size   = 500
  >>"%CFG%\config.toml" echo backoff_max  = 900
  >>"%CFG%\config.toml" echo jitter_ratio = 0.2
  >>"%CFG%\config.toml" echo.
  >>"%CFG%\config.toml" echo [privacy]
  >>"%CFG%\config.toml" echo collect_browser_history = true
  >>"%CFG%\config.toml" echo exclude_domains = ["*.banco.com", "*.salud.*"]
)

REM 5) Inno Setup opcional
if /I "%DO_ISCC%"=="iscc" (
  where iscc >nul 2>&1
  if errorlevel 1 (
    echo [WARN] ISCC.exe no esta en PATH. Abre Inno Setup y compila installer\ovana.iss manualmente.
  ) else (
    echo [INFO] Compilando instalador con ISCC...
    iscc "%ROOT%\installer\ovana.iss" || goto :fail
  )
)

echo [INFO] Listo. Binarios en: %DIST%
exit /b 0

:fail
echo [ERROR] Fallo la compilacion. Revisa el mensaje anterior.
exit /b 1
