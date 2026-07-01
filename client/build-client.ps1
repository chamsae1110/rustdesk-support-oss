# Build support-client.exe from this generic repo, injecting your real self-hosted
# server config at build time (the distributed client has the values baked in,
# because end-user machines have no RS_* environment variables).
#
# Usage:
#   1) Copy build.config.example -> build.config and fill in your real values.
#   2) Run:  powershell -ExecutionPolicy Bypass -File client\build-client.ps1
#
# build.config is git-ignored so your real domains/key never land in the repo.
param([string]$Config = "$PSScriptRoot\build.config")
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Config)) {
  throw "Missing $Config - copy client\build.config.example to client\build.config and fill in your values."
}

# --- read KEY=VALUE config ---
$cfg = @{}
Get-Content $Config | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
  $k, $v = $_ -split '=', 2
  $cfg[$k.Trim()] = $v.Trim()
}
foreach ($req in 'RS_SERVER', 'RS_RELAY', 'RS_PORTAL', 'RS_KEY') {
  if (-not $cfg[$req] -or $cfg[$req] -like '*example.com*' -or $cfg[$req] -like 'YOUR_*') {
    throw "build.config: set a real value for $req (still a placeholder)."
  }
}
$buildDir = if ($cfg.BUILD_DIR) { $cfg.BUILD_DIR } else { Join-Path $env:TEMP 'rds-oss-build' }
New-Item -ItemType Directory -Force $buildDir | Out-Null

# --- inject real values into a build copy of the client (preserve UTF-8 BOM) ---
$src = "$PSScriptRoot\support-client.ps1"
$bytes = [IO.File]::ReadAllBytes($src)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$t = [Text.Encoding]::UTF8.GetString($bytes)
if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
$t = $t.Replace("'id.example.com'", "'" + $cfg.RS_SERVER + "'")
$t = $t.Replace("'relay.example.com'", "'" + $cfg.RS_RELAY + "'")
$t = $t.Replace("'https://support.example.com'", "'" + $cfg.RS_PORTAL + "'")
$t = $t.Replace("'YOUR_RUSTDESK_SERVER_PUBLIC_KEY'", "'" + $cfg.RS_KEY + "'")
if ($cfg.RS_ORG) { $t = $t.Replace("else{'demo'}", "else{'" + $cfg.RS_ORG + "'}") }
[IO.File]::WriteAllText("$buildDir\support-client.ps1", $t, (New-Object Text.UTF8Encoding($hasBom)))

# --- SED with the chosen build dir ---
$sed = (Get-Content "$PSScriptRoot\support.sed.template" -Raw).Replace('C:\build', $buildDir)
[IO.File]::WriteAllText("$buildDir\support.sed", $sed, [Text.Encoding]::ASCII)

# --- build the self-extracting exe with the built-in IExpress ---
& "$env:SystemRoot\System32\iexpress.exe" /N /Q "$buildDir\support.sed" | Out-Null
Start-Sleep 2
$exe = "$buildDir\support-client.exe"
if (-not (Test-Path $exe)) { throw "IExpress did not produce $exe" }
Write-Host "Built: $exe"
Get-FileHash $exe -Algorithm SHA256 | Format-List Hash, Path
Write-Host "Sign this exe (e.g. via SignPath) before distributing. Keep the hash stable for SmartScreen reputation."
