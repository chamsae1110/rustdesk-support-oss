// remote-support 브로커 포털 (외부 의존성 0, Node >= 18)
// 흐름: 고객 클라 자동등록(비번 포함) → 상담원 대기실(마스터 로그인) → 워처 자동연결 / 대시보드 [연결].
//   heartbeat로 살아있는 클라만 유지, 연결/종료 시 대기실서 제거.
//
// ⚠️ MVP — 운영 전 강화 필수:
//   - in-memory → Postgres/Redis (이미 Postgres 보유)
//   - /operator, /api/* 실인증(기존 사이트 인증 / Cloudflare Access)
//   - 코드 엔트로피·레이트리밋·락아웃 강화, 쿠키 HTTPS-only
//   - PIPA: 접속/동의 감사로그를 durable 저장 (현재는 stdout 스텁)
//   - 화면/키입력 절대 로깅 금지, 비밀 마스킹
// support.example.com → http://localhost:3010 (기존 Cloudflare Tunnel 경유)

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const PORT = process.env.PORT || 3010;
const ID_SERVER = process.env.RUSTDESK_ID_SERVER || 'id.example.com';
const DOWNLOAD_URL = process.env.CLIENT_DOWNLOAD_URL || 'https://support.example.com/dl/support-client.exe';
const WAIT_TTL_MS = 30 * 60 * 1000;
const LIVE_TTL_MS = 40 * 1000; // 하트비트 끊긴(죽은) 대기 항목은 40초 후 제거 — 유령 대기 방지

// 조직 레지스트리. orgId -> 표시명
const ORGS = { demo: 'Demo Remote Support' };

const waiting = new Map();  // rustdeskId -> {orgId, name, agentId, password, createdAt, lastSeen}
const rate = new Map();     // ip -> {count, ts}
const now = () => Date.now();

setInterval(() => {
  const t = now();
  // 하트비트 끊긴(=죽은 클라) 또는 절대만료 항목 제거 — 유령 대기 방지
  for (const [k, v] of waiting) if (t - (v.lastSeen || v.createdAt) > LIVE_TTL_MS || t - v.createdAt > WAIT_TTL_MS) waiting.delete(k);
  // rate 맵도 윈도우 지난 항목 제거 — 느린 메모리 누수 방지
  for (const [k, r] of rate) if (t - r.ts > 60000) rate.delete(k);
}, 10000).unref();

const audit = (event, data) => console.log(JSON.stringify({ ts: new Date().toISOString(), event, ...data }));
function rateLimit(ip, limit = 10, win = 60000) {
  const t = now(); const r = rate.get(ip) || { count: 0, ts: t };
  if (t - r.ts > win) { r.count = 0; r.ts = t; }
  r.count++; rate.set(ip, r); return r.count <= limit;
}
const send = (res, s, b, type = 'application/json') => {
  res.writeHead(s, { 'content-type': type, 'cache-control': 'no-store' });
  res.end(typeof b === 'string' ? b : JSON.stringify(b));
};
const readJson = (req) => new Promise((ok) => {
  let d = ''; let over = false;
  req.on('data', c => {
    if (over) return;
    d += c;
    if (d.length > 65536) { over = true; d = ''; try { req.destroy(); } catch {} }  // 64KB 초과 = 차단(정상 요청은 수백 바이트)
  });
  req.on('end', () => { if (over) return ok({}); try { ok(JSON.parse(d || '{}')); } catch { ok({}); } });
  req.on('error', () => ok({}));
});
const esc = (s) => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// --- 마스터 계정(1번 상담원) 인증: HMAC 서명 쿠키 ---
const AGENT_PASS = process.env.AGENT_PASS || '';
const SESSION_SECRET = process.env.SESSION_SECRET || crypto.randomBytes(32).toString('hex');
const SESSION_TTL_MS = 12 * 60 * 60 * 1000; // 12h
function signSession(payload) {
  const data = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const mac = crypto.createHmac('sha256', SESSION_SECRET).update(data).digest('base64url');
  return `${data}.${mac}`;
}
function verifySession(tok) {
  if (!tok || tok.indexOf('.') < 0) return null;
  const [data, mac] = tok.split('.');
  const expected = crypto.createHmac('sha256', SESSION_SECRET).update(data).digest('base64url');
  const a = Buffer.from(mac), b = Buffer.from(expected);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try { const pl = JSON.parse(Buffer.from(data, 'base64url').toString()); return pl.exp > now() ? pl : null; } catch { return null; }
}
function cookie(req, name) {
  const c = req.headers.cookie || '';
  const mm = c.match(new RegExp('(?:^|; )' + name + '=([^;]+)'));
  return mm ? decodeURIComponent(mm[1]) : null;
}
const isAgent = (req) => !!verifySession(cookie(req, 'rs_sess'));

const server = http.createServer(async (req, res) => {
  const ip = (req.headers['cf-connecting-ip'] || req.socket.remoteAddress || '').toString();
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname; let m;

  // --- 마스터 로그인/로그아웃 ---
  if (req.method === 'POST' && p === '/api/login') {
    if (!rateLimit(ip, 8, 60000)) return send(res, 429, { error: 'rate_limited' });
    const b = await readJson(req);
    const pass = String(b.pass || '');
    const ok = AGENT_PASS.length > 0 && pass.length === AGENT_PASS.length &&
      crypto.timingSafeEqual(Buffer.from(pass), Buffer.from(AGENT_PASS));
    if (!ok) { audit('login_fail', { ip }); return send(res, 401, { error: 'invalid' }); }
    const tok = signSession({ role: 'agent1', exp: now() + SESSION_TTL_MS });
    audit('login_ok', { ip });
    res.writeHead(200, {
      'set-cookie': `rs_sess=${tok}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=${SESSION_TTL_MS / 1000}`,
      'content-type': 'application/json', 'cache-control': 'no-store',
    });
    return res.end(JSON.stringify({ ok: true }));
  }
  if (req.method === 'POST' && p === '/api/logout') {
    res.writeHead(200, { 'set-cookie': 'rs_sess=; HttpOnly; Path=/; Max-Age=0', 'content-type': 'application/json' });
    return res.end(JSON.stringify({ ok: true }));
  }

  // 엔드유저 랜딩
  if (req.method === 'GET' && (m = p.match(/^\/support\/([a-zA-Z0-9_-]+)$/))) {
    const name = ORGS[m[1]];
    if (!name) return send(res, 404, '알 수 없는 조직입니다.', 'text/plain; charset=utf-8');
    audit('support_page', { orgId: m[1], ip });
    return send(res, 200, landingHtml(m[1], name), 'text/html; charset=utf-8');
  }
  // 다운로드 리다이렉트
  if (req.method === 'GET' && (m = p.match(/^\/support\/([a-zA-Z0-9_-]+)\/client$/))) {
    audit('download', { orgId: m[1], ip });
    res.writeHead(302, { location: DOWNLOAD_URL }); return res.end();
  }
  // /dl/<file> 정적 다운로드 (단일 exe 호스팅)
  if (req.method === 'GET' && (m = p.match(/^\/dl\/([a-zA-Z0-9._-]+)$/))) {
    const fname = m[1];
    if (fname.includes('..')) return send(res, 400, 'bad request', 'text/plain');
    const fp = path.join('/app/dl', fname);
    if (!fs.existsSync(fp) || !fs.statSync(fp).isFile()) return send(res, 404, 'not found', 'text/plain');
    audit('dl', { file: fname, ip });
    res.writeHead(200, {
      'content-type': 'application/octet-stream',
      'content-disposition': `attachment; filename="${fname}"`,
      'content-length': fs.statSync(fp).size,
      'cache-control': 'no-store',
    });
    fs.createReadStream(fp).pipe(res);
    return;
  }
  // 자동등록 / 수동등록 (엔드유저 클라/런처 또는 페이지)
  if (req.method === 'POST' && p === '/api/register') {
    if (!rateLimit(ip, 20)) return send(res, 429, { error: 'rate_limited' });
    const b = await readJson(req);
    if (!ORGS[b.orgId] || !/^[0-9]{6,12}$/.test(String(b.rustdeskId || ''))) return send(res, 400, { error: 'bad_request' });
    const agentId = String(b.agentId || '1').slice(0, 8);
    // 자동수락 1회용 세션비번 — 있으면 저장(인증된 상담원에게만 제공). 비번은 로깅하지 않음.
    const password = b.password ? String(b.password).slice(0, 128) : '';
    waiting.set(String(b.rustdeskId), { orgId: b.orgId, name: String(b.name || '').slice(0, 40), agentId, password, createdAt: now(), lastSeen: now() });
    audit('register', { orgId: b.orgId, rustdeskId: b.rustdeskId, agentId, hasPw: !!password, ip });
    return send(res, 200, { ok: true });
  }
  // 세션 종료/취소 시 대기실에서 즉시 제거 (고객 런처가 창 닫힘 또는 상담원 연결종료 감지 시 호출)
  if (req.method === 'POST' && p === '/api/unregister') {
    if (!rateLimit(ip, 30)) return send(res, 429, { error: 'rate_limited' });
    const b = await readJson(req);
    const id = String(b.rustdeskId || '');
    const w = waiting.get(id);
    if (w) {
      // 비번 있는 항목은 올바른 세션비번을 제시해야 제거(무단 제거 방지). 비번 없으면 id만으로 허용.
      if (w.password && String(b.password || '') !== w.password) return send(res, 403, { error: 'forbidden' });
      waiting.delete(id);
      audit('unregister', { orgId: w.orgId, rustdeskId: id, ip });
    }
    return send(res, 200, { ok: true });
  }
  // 하트비트 — 대기 중 살아있음 표시(끊기면 포털이 유령으로 보고 40초 후 제거). 없으면 gone → 클라가 재등록.
  if (req.method === 'POST' && p === '/api/heartbeat') {
    const b = await readJson(req);
    const w = waiting.get(String(b.rustdeskId || ''));
    if (w) { w.lastSeen = now(); return send(res, 200, { ok: true }); }
    return send(res, 200, { ok: true, gone: true });
  }
  // 오퍼레이터 대기실 데이터 (인증 필요)
  if (req.method === 'GET' && (m = p.match(/^\/api\/waiting\/([a-zA-Z0-9_-]+)$/))) {
    if (!isAgent(req)) return send(res, 401, { error: 'auth' });
    const list = [...waiting.entries()].filter(([, v]) => v.orgId === m[1])
      .map(([id, v]) => ({ rustdeskId: id, name: v.name, agentId: v.agentId || '1', password: v.password || '', ageSec: Math.round((now() - v.createdAt) / 1000) }));
    return send(res, 200, { list });
  }
  // 오퍼레이터 대시보드 (인증 필요 — 아니면 로그인 페이지)
  if (req.method === 'GET' && p === '/operator') {
    if (!isAgent(req)) return send(res, 200, loginHtml(), 'text/html; charset=utf-8');
    return send(res, 200, operatorHtml(url.searchParams.get('org') || 'demo'), 'text/html; charset=utf-8');
  }
  // root -> default org landing (so https://support.example.com works directly)
  if (req.method === 'GET' && (p === '/' || p === '')) {
    res.writeHead(302, { location: `/support/${process.env.DEFAULT_ORG || 'demo'}` });
    return res.end();
  }
  if (p === '/healthz') return send(res, 200, { ok: true });
  return send(res, 404, 'not found', 'text/plain');
});

function landingHtml(orgId, name) {
  return `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>${esc(name)} 원격지원</title>
<style>body{font:16px/1.6 system-ui,sans-serif;max-width:560px;margin:40px auto;padding:0 16px;color:#1a1a1a}
.btn{display:inline-block;background:#1d9e75;color:#fff;padding:14px 22px;border-radius:10px;text-decoration:none;font-weight:600}
.box{background:#f5f4ef;border-radius:12px;padding:16px;margin:18px 0}.warn{background:#fff7e6;border:1px solid #ffd591;border-radius:12px;padding:14px 16px;margin:18px 0;font-size:14px}.warn p{margin:8px 0}.warn b{color:#ad6800}</style>
<h2>${esc(name)}</h2>
<p class=box>📥 <b>지원 프로그램이 자동으로 다운로드됩니다.</b><br>받은 파일을 <b>실행만</b> 하시면 상담원이 자동으로 연결됩니다.<br>번호 입력도, 버튼 클릭도 필요 없습니다.</p>
<p>다운로드가 시작되지 않으면 <a class=btn href="/support/${esc(orgId)}/client">여기를 눌러 받기</a></p>
<div class=warn>
<b>⚠️ 다운로드나 실행이 막히면 — 정상입니다. 아래대로 하세요</b>
<p><b>① 다운로드가 "위험"으로 막힐 때</b><br>브라우저 오른쪽 위 <b>다운로드 아이콘(↓)</b> → 파일 옆 <b>⋯</b>(또는 "유지") → <b>"위험한 파일 유지"</b> 클릭.</p>
<p><b>② 실행 시 파란 "Windows의 PC 보호" 창</b><br>창 가운데 작은 글씨 <b>"추가 정보"</b> 클릭 → 아래 나타나는 <b>"실행"</b> 버튼 클릭.</p>
<p style="color:#8c6d1f;font-size:13px;margin-top:10px">안전한 원격지원 프로그램입니다. 아직 서명 평판이 쌓이지 않아 경고가 뜰 뿐이며, 위 순서대로 하시면 됩니다. 어려우시면 상담원에게 전화 주세요.</p>
</div>
<script>setTimeout(function(){location.href='/support/${esc(orgId)}/client';},500);</script>`;
}

function loginHtml() {
  return `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>상담원 로그인</title>
<style>body{font:16px/1.6 system-ui,sans-serif;max-width:360px;margin:80px auto;padding:0 16px}
input{font-size:16px;padding:12px;width:100%;box-sizing:border-box;border:1px solid #ccc;border-radius:8px;margin:8px 0}
.btn{background:#2b6ff3;color:#fff;border:0;padding:12px;width:100%;border-radius:8px;font-weight:600;cursor:pointer}
.err{color:#d33;min-height:20px}</style>
<h2>1번 상담원 로그인</h2>
<input id=p type=password placeholder="마스터 비밀번호" autofocus>
<button class=btn onclick=login()>로그인</button>
<p class=err id=e></p>
<p style="margin-top:28px;font-size:13px;color:#888">이 기기에서 처음이라면 <a href="/dl/agent-client.exe">상담원 프로그램</a>을 먼저 받아 실행하세요 (RustDesk 자동 설정).</p>
<script>
async function login(){const pass=document.getElementById('p').value;
 const r=await fetch('/api/login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({pass:pass})});
 if(r.ok){location.href='/operator';}else{document.getElementById('e').textContent='비밀번호가 올바르지 않습니다.';}}
document.getElementById('p').addEventListener('keydown',function(ev){if(ev.key==='Enter')login();});
</script>`;
}

function operatorHtml(org) {
  return `<!doctype html><meta charset=utf-8><title>대기실 — ${esc(org)}</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:720px;margin:30px auto;padding:0 16px}
table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #eee;padding:8px;text-align:left}
.btn{background:#1d9e75;color:#fff;border:0;padding:8px 14px;border-radius:8px;cursor:pointer}
code{background:#f5f4ef;padding:2px 6px;border-radius:6px}</style>
<h2>대기실 — ${esc(org)}</h2>
<table><thead><tr><th>이름</th><th>RustDesk ID</th><th>경과</th><th>연결</th></tr></thead><tbody id=t></tbody></table>
<p><small>※ '연결' 클릭 = rustdesk://로 자동연결(이 기기에 RustDesk + 우리 서버 <code>${esc(ID_SERVER)}</code> 설정 필요 — 에이전트 셋업). 고객은 '수락'만. &nbsp;<a href="#" onclick="logout();return false">로그아웃</a></small></p>
<script>
async function load(){const r=await fetch('/api/waiting/${esc(org)}');
 if(r.status===401){location.reload();return;}
 const j=await r.json();
 document.getElementById('t').innerHTML=j.list.map(function(x){var u='rustdesk://connect/'+x.rustdeskId+(x.password?('?password='+encodeURIComponent(x.password)):'');var mode=x.password?' 🔓자동':'';return '<tr><td>'+(x.name||'-')+'</td><td><code>'+x.rustdeskId+'</code></td><td>'+x.ageSec+'s'+mode+'</td><td><a class=btn href="'+u+'">연결</a></td></tr>';}).join('');}
async function logout(){await fetch('/api/logout',{method:'POST'});location.reload();}
load();setInterval(load,3000);
</script>`;
}

const BIND = process.env.BIND || '127.0.0.1';
server.listen(PORT, BIND, () => console.log(`broker portal on http://${BIND}:${PORT} (id-server ${ID_SERVER})`));
