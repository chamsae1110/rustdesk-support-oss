# 1번 상담원(에이전트) 클라이언트 — 어느 기기(노트북/자리)든 실행:
#   RustDesk를 우리 서버로 설정 + rustdesk:// 핸들러 등록 + 인증 대시보드(마스터 로그인)를 연다.
param(
  [string]$Dashboard = $(if($env:RS_DASHBOARD){$env:RS_DASHBOARD}else{'https://support.example.com/operator'}),
  [string]$Server    = $(if($env:RS_SERVER){$env:RS_SERVER}else{'id.example.com'}),
  [string]$Relay     = $(if($env:RS_RELAY){$env:RS_RELAY}else{'relay.example.com'}),
  [string]$Key       = $(if($env:RS_KEY){$env:RS_KEY}else{'YOUR_RUSTDESK_SERVER_PUBLIC_KEY'})
)
$ErrorActionPreference = 'Stop'
if ($env:RS_SELFTEST -eq '1') { Write-Output 'parse-ok'; exit 0 }

$exe   = "$env:LOCALAPPDATA\rustdesk\rustdesk.exe"
$rdVer = '1.4.8'
$rdUrl = "https://github.com/rustdesk/rustdesk/releases/download/$rdVer/rustdesk-$rdVer-x86_64.exe"

# 1) RustDesk 확보(없으면 자동 다운로드/추출)
if (-not (Test-Path $exe)) {
  $dl = "$env:TEMP\rustdesk-setup.exe"
  try { Invoke-WebRequest $rdUrl -OutFile $dl -TimeoutSec 180 } catch {}
  if (Test-Path $dl) { $p = Start-Process $dl -PassThru; Start-Sleep 6; try { Stop-Process $p -Force } catch {} }
}

# 2) 우리 서버로 설정(검증된 직접쓰기)
$cfgDir = "$env:APPDATA\RustDesk\config"; New-Item -ItemType Directory -Force $cfgDir | Out-Null
Stop-Process -Name rustdesk -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 600
@"
rendezvous_server = ''
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '$Server'
relay-server = '$Relay'
key = '$Key'
"@ | Set-Content "$cfgDir\RustDesk2.toml" -Encoding utf8

# 2b) 상담원 기본 화면설정(UserDefaultConfig): 새 고객 세션이 '크기 조정 가능'(adaptive) + '반응 시간 최적화'(low)로 열리게.
@"
[options]
view_style = 'adaptive'
image_quality = 'low'
codec-preference = 'h265'
"@ | Set-Content "$cfgDir\RustDesk_default.toml" -Encoding utf8

# 3) rustdesk:// 핸들러 등록 (HKCU, 관리자 불필요) — 대시보드 '연결' 원클릭이 이 기기에서 동작하도록
if (Test-Path $exe) {
  try {
    $cls = 'HKCU:\Software\Classes\rustdesk'
    New-Item -Path "$cls\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path $cls -Name '(default)' -Value 'URL:RustDesk Protocol'
    New-ItemProperty -Path $cls -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    Set-ItemProperty -Path "$cls\shell\open\command" -Name '(default)' -Value ('"' + $exe + '" "%1"')
  } catch {}
}

# 4) RustDesk 실행 + 대시보드 열기(브라우저에서 마스터 로그인)
if (Test-Path $exe) { Start-Process $exe | Out-Null }
if (-not $env:AGENT_NOBROWSER) { Start-Process $Dashboard | Out-Null }

Write-Host ""
Write-Host "  [OK] 1번 상담원 모드 준비 완료" -ForegroundColor Green
Write-Host ""
Write-Host "  - RustDesk가 우리 서버($Server)로 설정되었습니다."
Write-Host "  - 브라우저 대기실에서 마스터 비밀번호로 로그인하세요."
Write-Host "  - 고객이 [1번 상담원]을 누르면 목록에 뜹니다. '연결'을 누르면 제어 시작."
Write-Host "  - 고객 화면의 '수락'을 고객이 누르면 연결됩니다."
Write-Host ""
Start-Sleep 4
