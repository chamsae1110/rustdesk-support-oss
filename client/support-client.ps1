# 고객용 원격지원 런처 (GUI) — 실행만 하면 자동등록+자동수락(무클릭). 상담원이 자동 연결.
# 검증된 메커니즘: RustDesk2.toml(서버+approve-mode=password) + RustDesk.toml(세션 평문비번, 서비스없이 자동수락)
#   + --get-id(폴링) + 포털 자동등록(비번 포함). 종료 시 비번 무효화. (소스검증 1.4.8)
param(
  [string]$Portal = $(if($env:RS_PORTAL){$env:RS_PORTAL}else{'https://support.example.com'}),
  [string]$OrgId  = $(if($env:RS_ORG){$env:RS_ORG}else{'demo'}),
  [string]$Server = $(if($env:RS_SERVER){$env:RS_SERVER}else{'id.example.com'}),
  [string]$Relay  = $(if($env:RS_RELAY){$env:RS_RELAY}else{'relay.example.com'}),
  [string]$Key    = $(if($env:RS_KEY){$env:RS_KEY}else{'YOUR_RUSTDESK_SERVER_PUBLIC_KEY'}),
  [string]$Name   = $env:COMPUTERNAME
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 셀프테스트(파싱/인코딩 확인용) — GUI 없이 종료
if ($env:RS_SELFTEST -eq '1') { Write-Host 'parse-ok'; exit 0 }

# 콘솔(파워쉘)·RustDesk 메인창 숨김 — 고객은 '원격지원' 런처 하나만 보이게.
$Win = Add-Type -Name RdWin -Namespace Helper -PassThru -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
'@
function Hide-Console { $c = $Win::GetConsoleWindow(); if ($c -ne [IntPtr]::Zero) { [void]$Win::ShowWindow($c, 0) } }
# RustDesk 메인창만 화면 밖(-32000)으로 이동해 숨김. ⚠️WM_CLOSE(=종료→오프라인)·SW_HIDE(=백그라운드 스로틀링→hbbs 오프라인) 둘 다 금지.
#  '표시' 상태를 유지해야 rustdesk가 온라인(hbbs 하트비트)을 유지함(호스트 실측 검증). CM 세션패널(--cm)은 투명성 위해 건드리지 않음.
function Hide-RustDesk {
  try {
    Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -notmatch '--cm' } | ForEach-Object {
      $mp = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
      if ($mp -and $mp.MainWindowHandle -ne [IntPtr]::Zero) { [void]$Win::SetWindowPos($mp.MainWindowHandle, [IntPtr]::Zero, -32000, -32000, 0, 0, 0x15) }
    }
  } catch {}
}
Hide-Console

# 이번 세션용 1회용 비번(자동수락용, URL-safe 영숫자만) — 상담원에게만 포털로 전달됨
$sessionPw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })

# 미처리 예외가 무서운 .NET 대화상자로 새지 않게 방어
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s,$ev) try { [System.Windows.Forms.MessageBox]::Show('일시적 오류입니다. 창을 닫고 다시 실행해주세요.','원격지원') | Out-Null } catch {} })

$exe   = "$env:LOCALAPPDATA\rustdesk\rustdesk.exe"
$rdVer = '1.4.8'
$rdUrl = "https://github.com/rustdesk/rustdesk/releases/download/$rdVer/rustdesk-$rdVer-x86_64.exe"

function Ensure-RustDesk {
  if (Test-Path $exe) { return $true }
  $bundled = Join-Path $PSScriptRoot 'rustdesk.exe'
  $inst = if (Test-Path $bundled) { $bundled } else {
    $dl = "$env:TEMP\rustdesk-setup.exe"
    try { Invoke-WebRequest $rdUrl -OutFile $dl -TimeoutSec 180 } catch { return $false }
    $dl
  }
  $p = Start-Process $inst -PassThru; Start-Sleep 6; try { Stop-Process $p -Force } catch {}
  return (Test-Path $exe)
}

if (-not (Ensure-RustDesk)) {
  [System.Windows.Forms.MessageBox]::Show('원격지원 프로그램을 준비할 수 없습니다. 인터넷을 확인 후 다시 실행해주세요.','원격지원') | Out-Null
  exit 1
}
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
approve-mode = 'password'
verification-method = 'use-permanent-password'
"@ | Set-Content "$cfgDir\RustDesk2.toml" -Encoding utf8
# 서비스 설치 없이 자동수락: RustDesk.toml에 이번 세션 평문 비번을 실행 전에 주입(기동 시 로드됨).
Set-Content "$cfgDir\RustDesk.toml" "password = '$sessionPw'" -Encoding utf8
Start-Process $exe | Out-Null

function Get-RdId {
  $o = Join-Path $env:TEMP ("rsid_" + [System.IO.Path]::GetRandomFileName() + ".txt")
  try {
    $q = Start-Process $exe -ArgumentList '--get-id' -PassThru -WindowStyle Hidden -RedirectStandardOutput $o -ErrorAction Stop
    if ($q) { [void]$q.WaitForExit(3000) }
  } catch {}
  $id = $null
  if (Test-Path $o) {
    $id = (Get-Content $o -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d{6,12}$' } | Select-Object -First 1)
    Remove-Item $o -ErrorAction SilentlyContinue
  }
  return $id
}

# --- 세션 상태 + 완전 정리(teardown) ---
$script:rdId = $null; $script:torn = $false; $script:sawSession = $false; $script:missCount = 0

function Test-RdSession {
  # 상담원 접속(원격 세션) 활성 여부 = RustDesk 연결관리자(CM) 존재. 파이프로 빠르게, 실패 시 프로세스로 확인.
  try { if ([System.IO.Directory]::GetFiles('\\.\pipe\') -match 'query_cm') { return $true } } catch {}
  try { if (Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '--cm' }) { return $true } } catch {}
  return $false
}

function Invoke-Teardown {
  # 멱등(1회만). 포털 등록 제거 + 세션비번 무효화 + 자동수락 해제 + RustDesk 완전 종료(백그라운드 잔존 방지).
  if ($script:torn) { return }
  $script:torn = $true
  try { $autoTimer.Stop() } catch {}
  try { $monTimer.Stop() } catch {}
  try { $hideTimer.Stop() } catch {}
  try { $hbTimer.Stop() } catch {}
  # 1) 포털 대기실에서 즉시 제거 (원 세션비번으로 인증)
  if ($script:rdId) {
    try {
      $ub = @{ orgId = $OrgId; rustdeskId = $script:rdId; password = $sessionPw } | ConvertTo-Json -Compress
      Invoke-RestMethod -Uri "$Portal/api/unregister" -Method Post -ContentType 'application/json' -Body $ub -TimeoutSec 6 | Out-Null
    } catch {}
  }
  # 2) 세션비번을 추측불가 랜덤으로 덮고 자동수락 해제(config)
  try {
    $rnd = -join ((48..57)+(97..122) | Get-Random -Count 28 | ForEach-Object { [char]$_ })
    Set-Content "$cfgDir\RustDesk.toml" "password = '$rnd'" -Encoding utf8 -ErrorAction SilentlyContinue
    @"
rendezvous_server = ''
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '$Server'
relay-server = '$Relay'
key = '$Key'
approve-mode = 'click'
"@ | Set-Content "$cfgDir\RustDesk2.toml" -Encoding utf8 -ErrorAction SilentlyContinue
  } catch {}
  # 3) RustDesk 완전 종료 (CM·메인·트레이 전부) — 백그라운드 잔존 방지
  try { Stop-Process -Name rustdesk -Force -ErrorAction SilentlyContinue } catch {}
}

# GUI — 실행 즉시 자동등록(버튼 없음). 고객은 실행만 하면 됨.
$form = New-Object System.Windows.Forms.Form
$form.Text = '원격지원'; $form.Size = New-Object System.Drawing.Size(440,260)
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.BackColor = [System.Drawing.Color]::White

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = '원격지원 연결 중'
$lbl.Font = New-Object System.Drawing.Font('Malgun Gothic',14,[System.Drawing.FontStyle]::Bold)
$lbl.Location = New-Object System.Drawing.Point(28,22); $lbl.Size = New-Object System.Drawing.Size(384,32)
$form.Controls.Add($lbl)

$status = New-Object System.Windows.Forms.Label
$status.Font = New-Object System.Drawing.Font('Malgun Gothic',12)
$status.Location = New-Object System.Drawing.Point(28,64); $status.Size = New-Object System.Drawing.Size(386,116)
$form.Controls.Add($status)

$retry = New-Object System.Windows.Forms.Button
$retry.Text = '다시 시도'
$retry.Font = New-Object System.Drawing.Font('Malgun Gothic',11,[System.Drawing.FontStyle]::Bold)
$retry.Location = New-Object System.Drawing.Point(28,188); $retry.Size = New-Object System.Drawing.Size(384,44)
$retry.BackColor = [System.Drawing.Color]::FromArgb(43,111,243); $retry.ForeColor = [System.Drawing.Color]::White
$retry.FlatStyle = 'Flat'; $retry.FlatAppearance.BorderSize = 0; $retry.Visible = $false
$form.Controls.Add($retry)

# 실행 즉시: --get-id 폴링(0.8초 간격, 최대 20회≈16초) → 준비되면 포털 자동등록
$script:tries = 0
$autoTimer = New-Object System.Windows.Forms.Timer
$autoTimer.Interval = 800
$autoTimer.Add_Tick({
  $script:tries++
  $id = Get-RdId
  if ($id) {
    $autoTimer.Stop()
    $script:rdId = $id
    try {
      $status.ForeColor = [System.Drawing.Color]::Black; $status.Text = '상담원에게 연결하는 중...'; $form.Refresh()
      $body = @{ orgId = $OrgId; rustdeskId = "$id"; agentId = '1'; name = $Name; password = $sessionPw } | ConvertTo-Json -Compress
      Invoke-RestMethod -Uri "$Portal/api/register" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 12 | Out-Null
      $hbTimer.Start()
      $status.ForeColor = [System.Drawing.Color]::FromArgb(29,158,117)
      $status.Text = "✅ 상담원을 기다리는 중입니다.`r`n`r`n이 창을 닫지 마시고 잠시만 기다려 주세요.`r`n상담원이 연결되면 자동으로 시작됩니다."
    } catch {
      $status.ForeColor = [System.Drawing.Color]::Red
      $status.Text = "연결 준비에 실패했습니다.`r`n인터넷 확인 후 [다시 시도] 를 눌러주세요."
      $retry.Visible = $true
    }
  } elseif ($script:tries -ge 20) {
    $autoTimer.Stop()
    $status.ForeColor = [System.Drawing.Color]::Red
    $status.Text = "연결 준비가 지연됩니다.`r`n[다시 시도] 를 누르거나 상담원에게 전화 주세요."
    $retry.Visible = $true
  }
})
$retry.Add_Click({
  $retry.Visible = $false; $script:tries = 0
  $status.ForeColor = [System.Drawing.Color]::Black; $status.Text = '연결을 준비하고 있어요...'
  $autoTimer.Start()
})
# 세션 감시: 상담원이 연결되면 안내 갱신, 세션이 끊기면(양쪽 누가 끊어도) 자동 정리+창 닫기.
$monTimer = New-Object System.Windows.Forms.Timer
$monTimer.Interval = 2000
$monTimer.Add_Tick({
  if (Test-RdSession) {
    $script:missCount = 0
    if (-not $script:sawSession) {
      $script:sawSession = $true
      try { $hbTimer.Stop() } catch {}
      # 연결됨 = 대기실에서 즉시 제거(중복/이중 자동연결 방지). 세션은 유지.
      if ($script:rdId) {
        try {
          $ub = @{ orgId = $OrgId; rustdeskId = $script:rdId; password = $sessionPw } | ConvertTo-Json -Compress
          Invoke-RestMethod -Uri "$Portal/api/unregister" -Method Post -ContentType 'application/json' -Body $ub -TimeoutSec 6 | Out-Null
        } catch {}
      }
      $status.ForeColor = [System.Drawing.Color]::FromArgb(29,158,117)
      $status.Text = "✅ 상담원이 연결되었습니다.`r`n`r`n지원이 진행 중입니다.`r`n(지원이 끝나면 자동으로 종료됩니다)"
    }
  } elseif ($script:sawSession) {
    # 세션이 있었는데 사라짐 = 종료. 2회 연속(≈4초) 확인 후 정리(순간 끊김 오탐 방지).
    $script:missCount++
    if ($script:missCount -ge 2) {
      $monTimer.Stop()
      $status.ForeColor = [System.Drawing.Color]::Black; $status.Text = '지원이 종료되었습니다. 정리 중...'; $form.Refresh()
      Invoke-Teardown
      try { $form.Close() } catch {}
    }
  }
})
# RustDesk 메인창을 계속 화면 밖으로: 시작 시 뜨는 창을 즉시 숨기고, 혹시 재등장해도 숨김. CM 세션패널은 제외.
$hideTimer = New-Object System.Windows.Forms.Timer
$hideTimer.Interval = 700
$hideTimer.Add_Tick({ Hide-Console; Hide-RustDesk })
# 하트비트: 대기 중 살아있음을 포털에 알림(끊기면 포털이 40초 후 유령으로 제거). 등록 성공 시 시작, 연결되면 중지.
$hbTimer = New-Object System.Windows.Forms.Timer
$hbTimer.Interval = 12000
$hbTimer.Add_Tick({
  if (-not $script:rdId -or $script:sawSession) { return }
  try {
    $hb = @{ orgId = $OrgId; rustdeskId = $script:rdId } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Uri "$Portal/api/heartbeat" -Method Post -ContentType 'application/json' -Body $hb -TimeoutSec 8
    if ($r.gone) {
      $body = @{ orgId = $OrgId; rustdeskId = $script:rdId; agentId = '1'; name = $Name; password = $sessionPw } | ConvertTo-Json -Compress
      Invoke-RestMethod -Uri "$Portal/api/register" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 8 | Out-Null
    }
  } catch {}
})
$form.Add_Shown({
  $status.ForeColor = [System.Drawing.Color]::Black; $status.Text = '연결을 준비하고 있어요...'; $form.Refresh()
  $autoTimer.Start(); $monTimer.Start(); $hideTimer.Start()
})
# 창을 닫으면(또는 세션 종료 감지 시) 완전 정리 — 멱등 teardown.
$form.Add_FormClosing({ Invoke-Teardown })
[void]$form.ShowDialog()
