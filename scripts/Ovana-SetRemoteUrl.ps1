param([Parameter(Mandatory=$true)][string]$RemoteUrl)
$ErrorActionPreference = 'Stop'
$ConfigDir  = Join-Path $env:ProgramData 'Ovana'
$ConfigFile = Join-Path $ConfigDir 'config.toml'
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
if (-not (Test-Path $ConfigFile)) {@"
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
"@ | Set-Content -Path $ConfigFile -Encoding UTF8 }
Copy-Item $ConfigFile "$ConfigFile.bak" -Force
$content = Get-Content $ConfigFile -Raw
if ($content -notmatch '(?ms)^\[server\]') { $content = "[server]`nremote_url = ""`napi_token  = ""`n`n" + $content }
if ($content -match '(?ms)^\s*remote_url\s*=\s*"\s*"') {
  $content = [regex]::Replace($content, '(?ms)^\s*remote_url\s*=\s*"\s*"', 'remote_url = "' + [regex]::Escape($RemoteUrl) + '"')
} elseif ($content -notmatch '(?ms)^\s*remote_url\s*=') {
  $content = $content -replace '(?ms)^\[server\]\s*', "[server]`nremote_url = ""$([regex]::Escape($RemoteUrl))""`n"
}
Set-Content -Path $ConfigFile -Value $content -Encoding UTF8
Start-Sleep -Seconds 2
& sc.exe stop OvanaSync | Out-Null
& sc.exe start OvanaSync | Out-Null
