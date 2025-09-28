<#
.SYNOPSIS
  Compila y arma el bundle del Agente Ovana para el instalador único.
.DESCRIPTION
  - Construye ovana-sync (PyInstaller)
  - Construye ovana-agent (GUI aw-qt, PyInstaller)
  - (Opcional) Construye server Rust si existe carpeta
  - Copia binarios a C:\ovana-agent\build\dist\{server,gui,sync}
  - (Opcional) Invoca Inno Setup (ISCC) para generar OvanaAgentSetup.exe
.PARAMETER Server
  "rust" | "python" | "skip"  (default: rust si hay carpeta; si no, skip)
.PARAMETER Icon
  Ruta a .ico para el GUI (default: C:\ovana-agent\branding\icons\ovana.ico)
.PARAMETER CompileInstaller
  Switch para compilar Inno Setup con ISCC.exe si está en PATH
.EXAMPLE
  # Compilar todo (detecta server rust si existe) y generar instalador
  .\scripts\build.ps1 -CompileInstaller
.EXAMPLE
  # Forzar usar server Python empaquetado por tu cuenta (no compila rust)
  .\scripts\build.ps1 -Server python -CompileInstaller
#>
param(
  [ValidateSet('rust','python','skip')]
  [string]$Server = 'skip',
  [string]$Icon = 'C:\ovana-agent\branding\icons\ovana.ico',
  [switch]$CompileInstaller
)

$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Warning $m }
function Die($m){ Write-Error $m; exit 1 }

$Root = 'C:\ovana-agent'
$Src  = Join-Path $Root 'src'
$Dist = Join-Path $Root 'build\dist'
$Cfg  = Join-Path $Root 'build\config'
$BinServer = Join-Path $Dist 'server'
$BinSync   = Join-Path $Dist 'sync'
$BinGui    = Join-Path $Dist 'gui'

# Crear carpetas
mkdir $BinServer -Force | Out-Null
mkdir $BinSync   -Force | Out-Null
mkdir $BinGui    -Force | Out-Null
mkdir $Cfg       -Force | Out-Null

# 1) Server (opcional)
$ServerRustDir = Join-Path $Src 'ovanaw-server-rust'
if ($Server -eq 'rust' -or ($Server -eq 'skip' -and (Test-Path $ServerRustDir))) {
  if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { Warn 'cargo no encontrado, se omitirá build de server rust'; }
  else {
    Info "Compilando server (Rust) en $ServerRustDir"
    Push-Location $ServerRustDir
    cargo build --release
    Copy-Item .\target\release\aw-server.exe $BinServer\aw-server.exe -Force
    Pop-Location
    $Server = 'rust'
  }
}
elseif ($Server -eq 'python') {
  Warn 'Modo server=python: este script NO empaqueta el server Python. Copia tu aw-server-py.exe a build\dist\server manualmente.'
}
else {
  Warn 'Server omitido (skip). Asegúrate de colocar aw-server.exe o aw-server-py.exe en build\dist\server.'
}

# 2) Sync (PyInstaller)
$SyncDir = Join-Path $Src 'ovana-sync'
if (-not (Test-Path $SyncDir)) { Die "No existe $SyncDir (copia la carpeta ovana-sync)." }
Info "Construyendo ovana-sync"
Push-Location $SyncDir
python -m venv .venv
.\.venv\Scripts\pip install --upgrade pip -r requirements.txt pyinstaller
pyinstaller --noconfirm --onefile --name ovana-sync sync.py
Copy-Item .\dist\ovana-sync.exe $BinSync\ovana-sync.exe -Force
Pop-Location

# 3) GUI (PyInstaller)
$QtDir = Join-Path $Src 'ovanaw-qt'
if (-not (Test-Path $QtDir)) { Die "No existe $QtDir (clona/crea ovanaw-qt)." }
if (-not (Test-Path $Icon)) { Warn "Icono $Icon no existe; se usará sin --icon" }
Info "Construyendo ovana-agent (GUI)"
Push-Location $QtDir
python -m venv .venv
.\.venv\Scripts\pip install --upgrade pip -r requirements.txt pyinstaller
$pyi = 'pyinstaller --noconfirm --onefile --windowed --name ovana-agent -m aw_qt'
if (Test-Path $Icon) { $pyi += " --icon `"$Icon`"" }
cmd /c $pyi
Copy-Item .\dist\ovana-agent.exe $BinGui\ovana-agent.exe -Force
Pop-Location

# 4) Config base (si no existe)
$CfgFile = Join-Path $Cfg 'config.toml'
if (-not (Test-Path $CfgFile)) {
  Info 'Creando config.toml base (remote_url vacío)'
  @"
[server]
remote_url = ""
api_token  = ""

[sync]
interval     = 60
batch_size   = 500
backoff_max  = 900
jitter_ratio = 0.2

[privacy]
collect_browser_history = true
exclude_domains = ["*.banco.com", "*.salud.*"]
"@ | Set-Content -Path $CfgFile -Encoding UTF8
}

# 5) Compilar instalador (opcional)
if ($CompileInstaller) {
  if (-not (Get-Command iscc -ErrorAction SilentlyContinue)) {
    Warn 'ISCC.exe (Inno Setup) no está en PATH. Abre Inno y compila installer/ovana.iss manualmente.'
  } else {
    $Iss = Join-Path $Root 'installer\ovana.iss'
    if (-not (Test-Path $Iss)) { Die "No existe $Iss" }
    Info "Compilando instalador con ISCC: $Iss"
    & iscc $Iss | Write-Host
  }
}

Info "Listo. Binarios en: $Dist"
if ($Server -eq 'rust') { Info 'Incluido: aw-server.exe (Rust)' } else { Info 'Server: no empaquetado por este script' }
Info 'Incluido: ovana-sync.exe'
Info 'Incluido: ovana-agent.exe'
