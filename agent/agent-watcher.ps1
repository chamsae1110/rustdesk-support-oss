# 상담원 무인 자동연결 워처 — 상담원(operator) 본인 PC에서 실행.
# 포털 대기실(/api/waiting)을 감시해, 새 고객이 등록되면 rustdesk --connect <id> --password <pw> 로 자동 연결.
# 전제: (1) 이 PC에 agent-client 로 RustDesk가 우리 서버로 설정돼 있어야 함.
#       (2) 고객이 무클릭(수락 없음)이 되려면 고객측 자동수락(Path-2 또는 B) + 세션비번이 포털에 있어야 함.
#           비번 없는 고객(Path-1)은 자동연결 안 하고 "수동 연결 필요"로 알림만.
param(
  [string]$Portal = $(if($env:RS_PORTAL){$env:RS_PORTAL}else{'https://support.example.com'}),
  [string]$Org    = $(if($env:RS_ORG){$env:RS_ORG}else{'demo'}),
  [int]$IntervalSec = 3
)
$ErrorActionPreference = 'Stop'
if ($env:RS_SELFTEST -eq '1') { Write-Output 'parse-ok'; exit 0 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$rd = if (Test-Path "C:\Program Files\RustDesk\rustdesk.exe") { "C:\Program Files\RustDesk\rustdesk.exe" }
      elseif (Test-Path "$env:LOCALAPPDATA\rustdesk\rustdesk.exe") { "$env:LOCALAPPDATA\rustdesk\rustdesk.exe" } else { $null }
if (-not $rd) { Write-Host "RustDesk를 찾을 수 없습니다. 먼저 agent-client 로 상담원 셋업을 하세요." -ForegroundColor Red; Read-Host "엔터로 종료"; exit 1 }

# 마스터 비번 → 로그인(세션 쿠키). 비번은 화면/로그에 남기지 않음.
$sec  = Read-Host "마스터 비밀번호" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$script:pass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
$script:ws = New-Object Microsoft.PowerShell.Commands.WebRequestSession
function Login {
  try {
    Invoke-RestMethod -Uri "$Portal/api/login" -Method Post -ContentType 'application/json' `
      -Body (@{ pass = $script:pass } | ConvertTo-Json) -WebSession $script:ws -TimeoutSec 12 | Out-Null
    return $true
  } catch { return $false }
}
if (-not (Login)) { Write-Host "로그인 실패 — 마스터 비밀번호를 확인하세요." -ForegroundColor Red; Read-Host "엔터로 종료"; exit 1 }
Write-Host "OK 로그인 성공. 대기실 감시 시작 (이 창을 닫으면 중지)." -ForegroundColor Green
Write-Host ("포털=$Portal  조직=$Org  주기=${IntervalSec}s") -ForegroundColor DarkGray

$seen = @{}
while ($true) {
  $list = $null
  try {
    $list = (Invoke-RestMethod -Uri "$Portal/api/waiting/$Org" -WebSession $script:ws -TimeoutSec 10).list
  } catch {
    # 401(쿠키 12h 만료) 등 → 재로그인
    if (Login) { Start-Sleep -Seconds $IntervalSec; continue }
    Write-Host ("[{0}] 대기실 조회 실패, 5초 후 재시도" -f (Get-Date -Format HH:mm:ss)) -ForegroundColor DarkYellow
    Start-Sleep 5; continue
  }
  # 상담원이 이미 원격세션 중이면(들어오는 CM 또는 나가는 연결) 자동연결 스킵 — 1:1 보장, 진짜 고객 2명 겹침 방지.
  $busy = $false
  try { if ([System.IO.Directory]::GetFiles('\\.\pipe\') -match 'query_cm') { $busy = $true } } catch {}
  if (-not $busy) { try { if (Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '--connect' }) { $busy = $true } } catch {} }
  # 1:1 — 비번 있는 대기 고객 중 '가장 최근(경과 최소)' 1명만 자동연결. 유령·이중연결 방지. 60초 지나면 재시도 허용.
  $nowt = Get-Date
  $cands = @(@($list) | Where-Object {
    $_.password -and "$($_.rustdeskId)" -and
    ((-not $seen.ContainsKey("$($_.rustdeskId)")) -or (($nowt - $seen["$($_.rustdeskId)"]).TotalSeconds -gt 60))
  })
  if ($busy -and $cands.Count -gt 0) {
    Write-Host ("[{0}] 이미 원격세션 중 — 대기 {1}명 자동연결 보류(1:1)" -f (Get-Date -Format HH:mm:ss), $cands.Count) -ForegroundColor DarkYellow
  } elseif ($cands.Count -gt 0) {
    $target = $cands | Sort-Object { [int]$_.ageSec } | Select-Object -First 1
    $tid = "$($target.rustdeskId)"
    $seen[$tid] = Get-Date
    if ($cands.Count -gt 1) { Write-Host ("[{0}] 대기 {1}명 — 1:1이라 최신 {2}만 연결(나머지 무시)" -f (Get-Date -Format HH:mm:ss), $cands.Count, $tid) -ForegroundColor DarkYellow }
    # 재사용 ID의 옛 화면설정을 무시하고 기본값(크기조정 가능+반응시간 최적화)으로 열리게 peer 파일 삭제
    Remove-Item ("$env:APPDATA\RustDesk\config\peers\$tid.toml") -Force -ErrorAction SilentlyContinue
    Write-Host ("[{0}] 자동연결 → {1} ({2})" -f (Get-Date -Format HH:mm:ss), $tid, $target.name) -ForegroundColor Cyan
    try { Start-Process $rd -ArgumentList '--connect', $tid, '--password', "$($target.password)" | Out-Null }
    catch { Write-Host ("   연결 실행 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red }
  }
  # 대기실에서 사라진 id는 seen에서 제거(다시 오면 재연결 허용)
  $cur = @($list | ForEach-Object { "$($_.rustdeskId)" })
  foreach ($k in @($seen.Keys)) { if ($cur -notcontains $k) { $seen.Remove($k) } }
  Start-Sleep -Seconds $IntervalSec
}
