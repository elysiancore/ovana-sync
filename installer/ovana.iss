; Ovana Agent – Inno Setup Script (único instalador)
; Requisitos: Inno Setup 6.x
; Objetivo: instalar Server (Rust/Python), Sync, GUI, config y registrar servicios.
; NOTA SOBRE URL REMOTA:
;  - El instalador NO impone una URL fija.
;  - Puede recibir /REMOTEURL=... (GPO/despliegue silencioso) o el usuario puede escribirla en una página opcional.
;  - Si se deja vacía, se instala en modo "pendiente" y la URL puede definirse después (GPO/archivo/política).

#define MyAppName "Ovana Agent"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "elysiancore"
#define MyAppExeName "ovana-agent.exe"

[Setup]
AppId={{6C1C7C28-4C9B-4E60-9F42-5A1B1E6E0F6E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={pf64}\Ovana\Agent
DefaultGroupName=Ovana
DisableDirPage=no
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename=OvanaAgentSetup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
ChangesAssociations=no
WizardStyle=modern
; Permitir instalación silenciosa
SilentInstall=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Files]
; === Entradas binarias (ajusta rutas de origen antes de compilar) ===
; Server (elige uno; puedes incluir ambos y activar uno por parámetro si quieres)
Source: "C:\ovana-agent\build\dist\server\aw-server.exe"; DestDir: "{app}\bin"; Flags: ignoreversion ; Comment: "Server (Rust)"
; Source: "C:\ovana-agent\build\dist\server\aw-server-py.exe"; DestDir: "{app}\bin"; Flags: ignoreversion ; Comment: "Server (Python empaquetado)"

; Sync
Source: "C:\ovana-agent\build\dist\sync\ovana-sync.exe"; DestDir: "{app}\bin"; Flags: ignoreversion

; GUI (bandeja)
Source: "C:\ovana-agent\build\dist\gui\ovana-agent.exe"; DestDir: "{app}\bin"; Flags: ignoreversion

; Config base (plantilla)
Source: "C:\ovana-agent\build\config\config.toml"; DestDir: "{commonappdata}\Ovana"; DestName: "config.toml"; Flags: onlyifdoesntexist

; Iconos opcionales
Source: "C:\ovana-agent\branding\icons\ovana.ico"; DestDir: "{app}\branding"; Flags: ignoreversion; Excludes: ""

[Tasks]
; Acceso directo del GUI en Inicio (usuario actual)
Name: "startupicon"; Description: "Iniciar Ovana Agent al iniciar sesión (usuario actual)"; Flags: checkedonce
; Acceso directo en Inicio para TODOS los usuarios (requiere admin) – opcional, seleccionable con /TASKS=allusersstartup
Name: "allusersstartup"; Description: "Iniciar Ovana Agent para todos los usuarios (Todos los perfiles)"; Flags: unchecked

[Icons]
; Menú inicio (grupo de programas)
Name: "{group}\Ovana Agent"; Filename: "{app}\bin\{#MyAppExeName}"
; Inicio (usuario actual) – tarea marcada por defecto
Name: "{userstartup}\Ovana Agent"; Filename: "{app}\bin\{#MyAppExeName}"; Tasks: startupicon
; Inicio (TODOS los usuarios) – seleccionable con /TASKS=allusersstartup
Name: "{commonstartup}\Ovana Agent"; Filename: "{app}\bin\{#MyAppExeName}"; Tasks: allusersstartup

[Run]
; Registrar servicios con sc.exe (delayed-auto + auto-restart)
; Server (Rust) – ajusta si usas el Python empaquetado
Filename: "{cmd}"; Parameters: "/C sc create OvanaServer binPath= \"{app}\bin\aw-server.exe\" start= auto"; Flags: runhidden
Filename: "{cmd}"; Parameters: "/C sc failure OvanaServer reset= 60 actions= restart/5000"; Flags: runhidden
Filename: "{cmd}"; Parameters: "/C sc failureflag OvanaServer 1"; Flags: runhidden
Filename: "{cmd}"; Parameters: "/C sc config OvanaServer start= delayed-auto"; Flags: runhidden

; Sync
Filename: "{cmd}"; Parameters: "/C sc create OvanaSync binPath= \"{app}\bin\ovana-sync.exe\" start= auto"; Flags: runhidden
Filename: "{cmd}"; Parameters: "/C sc failure OvanaSync reset= 60 actions= restart/5000"; Flags: runhidden
Filename: "{cmd}"; Parameters: "/C sc failureflag OvanaSync 1"; Flags: runhidden
Filename: "{cmd}"; Parameters: "/C sc config OvanaSync start= delayed-auto"; Flags: runhidden

; Iniciar servicios al terminar
Filename: "{cmd}"; Parameters: "/C sc start OvanaServer"; Flags: runhidden
Filename: "{cmd}"; Parameters: "/C sc start OvanaSync"; Flags: runhidden

[Code]
var
  RemotePage: TInputQueryWizardPage;
  RemoteURL: string;
  TokenParam: string;

function GetCmdParamValue(const Name: string): string;
var
  S, Pfx: string;
  I, J: Integer;
begin
  Result := '';
  S := GetCmdTail;
  Pfx := '/' + UpperCase(Name) + '=';
  I := Pos(UpperCase(Pfx), UpperCase(S));
  if I > 0 then begin
    J := I + Length(Pfx);
    Result := Copy(S, J, MaxInt);
    if Pos(' ', Result) > 0 then
      Result := Copy(Result, 1, Pos(' ', Result)-1);
  end;
end;

procedure InitializeWizard;
begin
  RemotePage := CreateInputQueryPage(wpSelectTasks,
    'URL remota (opcional)',
    'Define a qué servidor enviará los datos el agente',
    'Puedes dejarlo vacío si vas a establecerlo más tarde por GPO o script.');
  RemotePage.Add('&Remote URL (https):', False);

  RemoteURL := GetCmdParamValue('REMOTEURL');
  if RemoteURL <> '' then
    RemotePage.Values[0] := RemoteURL;

  TokenParam := GetCmdParamValue('TOKEN');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = RemotePage.ID then begin
    RemoteURL := Trim(RemotePage.Values[0]);
    if RemoteURL <> '' then begin
      if not (Pos('http://', LowerCase(RemoteURL)) = 1) and
         not (Pos('https://', LowerCase(RemoteURL)) = 1) then begin
        MsgBox('La URL debe iniciar con http:// o https:// (recomendado https).', mbError, MB_OK);
        Result := False;
      end;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigDir, ConfigFile, S: string;
begin
  if CurStep = ssPostInstall then begin
    ConfigDir := ExpandConstant('{commonappdata}') + '\Ovana';
    ConfigFile := ConfigDir + '\config.toml';

    if not DirExists(ConfigDir) then
      ForceDirectories(ConfigDir);

    ; // Construir el contenido del TOML
    S := '';
    S := S + '[server]' + #13#10;
    if RemoteURL <> '' then
      S := S + 'remote_url = "' + RemoteURL + '"' + #13#10
    else
      S := S + 'remote_url = ""' + #13#10;  // pendiente si vacío

    if TokenParam <> '' then
      S := S + 'api_token  = "' + TokenParam + '"' + #13#10
    else
      S := S + 'api_token  = ""' + #13#10;

    S := S + #13#10 + '[sync]' + #13#10;
    S := S + 'interval     = 60' + #13#10;
    S := S + 'batch_size   = 500' + #13#10;
    S := S + 'backoff_max  = 900' + #13#10;
    S := S + 'jitter_ratio = 0.2' + #13#10;

    S := S + #13#10 + '[privacy]' + #13#10;
    S := S + 'collect_browser_history = true' + #13#10;
    S := S + 'exclude_domains = ["*.banco.com", "*.salud.*"]' + #13#10;

    ; // Escribir/actualizar config (no sobreescribir si el usuario ya tenía una)
    if not FileExists(ConfigFile) then begin
      SaveStringToFile(ConfigFile, S, False);
    end else begin
      ; // Actualización conservadora: solo reemplazar remote_url/api_token si se pasaron por línea de comandos
      if (RemoteURL <> '') or (TokenParam <> '') then begin
        SaveStringToFile(ConfigFile, S, False);
      end;
    end;
  end;
end;

[UninstallRun]
; Intentar detener y eliminar servicios al desinstalar
Filename: "{cmd}"; Parameters: "/C sc stop OvanaSync"; Flags: runhidden; RunOnceId: "stop-sync"
Filename: "{cmd}"; Parameters: "/C sc stop OvanaServer"; Flags: runhidden; RunOnceId: "stop-server"
Filename: "{cmd}"; Parameters: "/C sc delete OvanaSync"; Flags: runhidden; RunOnceId: "del-sync"
Filename: "{cmd}"; Parameters: "/C sc delete OvanaServer"; Flags: runhidden; RunOnceId: "del-server"
