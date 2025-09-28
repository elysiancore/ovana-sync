# ovana-sync (Windows Service)

Servicio de sincronización **offline→online** para Ovana:
- Lee eventos del **servidor local** ActivityWatch (`http://127.0.0.1:5600/api/0`)
- Mantiene **checkpoints** por bucket en `%PROGRAMDATA%\Ovana\sync.db`
- Envía en **batches ordenados** al backend remoto (`remote_url`) con **Idempotency-Key**
- **Backoff exponencial** con jitter ante fallos de red y 5xx/429
- Avanza checkpoints **solo** con 2xx → sin duplicados

## Requisitos
- Windows 10/11 x64
- Python 3.11+

```powershell
cd C:\ovana-agent\src\ovana-sync
python -m venv .venv
.\.venv\Scripts\pip install --upgrade pip -r requirements.txt
```

## Desarrollo (prueba local)
```powershell
python .\sync.py --verbose
```

## Empaquetado (EXE)
```powershell
.\.venv\Scripts\pip install pyinstaller
pyinstaller --noconfirm --onefile --name ovana-sync sync.py
Copy-Item .\dist\ovana-sync.exe C:\ovana-agent\build\dist\sync\ -Force
```

## Registro como servicio
```powershell
sc create "OvanaSync" binPath= "C:\ovana-agent\build\dist\sync\ovana-sync.exe" start= auto
sc failure "OvanaSync" reset= 60 actions= restart/5000
sc failureflag "OvanaSync" 1
sc config "OvanaSync" start= delayed-auto
sc start "OvanaSync"
```

## Configuración
`%PROGRAMDATA%\Ovana\config.toml`
```toml
[server]
remote_url = ""   # se puede setear en el instalador o por GPO
api_token  = ""

[sync]
interval     = 60
batch_size   = 500
backoff_max  = 900
jitter_ratio = 0.2
```

## Endpoints esperados en el backend remoto
- **POST** `/ingest/events` → body `{bucket, events, first_ts, last_ts, count, source, schema}`
  - Usa cabecera `Idempotency-Key`
- (Opcional) **POST** `/agent/heartbeat` → salud del cliente
