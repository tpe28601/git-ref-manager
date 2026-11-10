'use strict';
// Git Ref Manager Web 控制台前端
// 圖標一律使用內嵌 Lucide SVG（離線可用，不使用 emoji 與外部字型）。

// ---------- 小工具 ----------
function $(id) { return document.getElementById(id); }
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

// Lucide 圖標（ISC 授權）：stroke 繼承 currentColor
var ICONS = (function () {
  function svg(body, size) {
    var s = size || 15;
    return '<svg class="ic" width="' + s + '" height="' + s + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
      'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + body + '</svg>';
  }
  return {
    sun: svg('<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>'),
    moon: svg('<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>'),
    monitor: svg('<rect width="20" height="14" x="2" y="3" rx="2"/><line x1="8" x2="16" y1="21" y2="21"/><line x1="12" x2="12" y1="17" y2="21"/>'),
    folder: svg('<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>'),
    folderOpen: svg('<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>'),
    gitBranch: svg('<line x1="6" x2="6" y1="3" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/>'),
    search: svg('<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>'),
    check: svg('<path d="M20 6 9 17l-5-5"/>'),
    x: svg('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>'),
    alert: svg('<path d="m21.73 18-8-14a2 2 0 0 0-3.46 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/>'),
    chevronUp: svg('<path d="m18 15-6-6-6 6"/>'),
    chevronDown: svg('<path d="m6 9 6 6 6-6"/>'),
    chevronRight: svg('<path d="m9 18 6-6-6-6"/>'),
    hardDrive: svg('<line x1="22" x2="2" y1="12" y2="12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><line x1="6" x2="6.01" y1="16" y2="16"/><line x1="10" x2="10.01" y1="16" y2="16"/>')
  };
})();

// ---------- 排隊提示：後端單執行緒迴圈，browse／Job／前筆驗證可能占用，超過 1.2 秒顯示提示 ----------
let slowInflight = 0;
let slowTimer = null;
function slowTrackBegin() {
  slowInflight++;
  if (!slowTimer) slowTimer = setTimeout(function () { $('slow-hint').classList.remove('hidden'); }, 1200);
}
function slowTrackEnd() {
  slowInflight = Math.max(0, slowInflight - 1);
  if (slowInflight === 0) {
    if (slowTimer) { clearTimeout(slowTimer); slowTimer = null; }
    $('slow-hint').classList.add('hidden');
  }
}

async function apiPost(path, body) {
  slowTrackBegin();
  try {
    const res = await fetch(path, {
      method: 'POST',
      // X-Toolbox-Request：伺服器要求所有 POST 都帶這個標頭（防止其他網頁偷送請求）
      headers: { 'Content-Type': 'application/json', 'X-Toolbox-Request': '1' },
      body: JSON.stringify(body || {})
    });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch (e) { /* 非 JSON */ }
    return { status: res.status, json: json, text: text };
  } finally {
    slowTrackEnd();
  }
}

// ---------- 功能說明彈視 ----------
var HELP_TITLES = { sync: '功能說明：本地同步', fetch: '功能說明：Fetch Origin', worktree: '功能說明：Worktree' };
function helpClose() { $('help-modal').classList.add('hidden'); }
document.querySelectorAll('.help-btn').forEach(function (btn) {
  btn.addEventListener('click', function () {
    document.querySelectorAll('.help-body').forEach(function (b) { b.classList.add('hidden'); });
    $('help-' + btn.dataset.help).classList.remove('hidden');
    $('help-title').textContent = HELP_TITLES[btn.dataset.help] || '功能說明';
    $('help-modal').classList.remove('hidden');
  });
});
$('help-close').addEventListener('click', helpClose);
$('help-ok').addEventListener('click', helpClose);
$('help-modal').addEventListener('click', function (ev) { if (ev.target === this) helpClose(); });

// ---------- 主題（ui-kit 3.0：tb-theme.js 負責套用與記憶；Hub 嵌入時由網址與 postMessage 控制） ----------
(function initTheme() {
  var ORDER = ['light', 'dark', 'system'];
  var LABEL = { light: '淺色', dark: '深色', system: '跟隨系統' };
  function paint() {
    var t = window.TbTheme ? TbTheme.get() : { mode: 'system', resolved: 'light' };
    var icon = t.mode === 'system' ? ICONS.monitor : (t.mode === 'dark' ? ICONS.moon : ICONS.sun);
    $('theme-toggle').innerHTML = icon;
    $('theme-toggle').title = '主題：' + LABEL[t.mode] + '（點一下切換）';
  }
  paint();
  document.addEventListener('tb-theme-change', paint);
  $('theme-toggle').addEventListener('click', function () {
    if (!window.TbTheme) return;
    var cur = TbTheme.get().mode;
    TbTheme.set(ORDER[(ORDER.indexOf(cur) + 1) % ORDER.length]);
  });
})();

// ---------- 分頁 ----------
document.querySelectorAll('.tab-btn').forEach(function (btn) {
  btn.addEventListener('click', function () {
    document.querySelectorAll('.tab-btn').forEach(function (b) { b.classList.remove('active'); });
    document.querySelectorAll('main .tab').forEach(function (s) { s.classList.remove('active'); });
    btn.classList.add('active');
    $('tab-' + btn.dataset.tab).classList.add('active');
    document.body.dataset.tab = btn.dataset.tab;   // 控制 tabs 列右側功能說明鈕的顯示
  });
});

// ---------- 伺服器等狀態 ----------
async function pollState() {
  const badge = $('server-state');
  try {
    const res = await fetch('/api/state');
    const s = await res.json();
    if (s.busy) { badge.textContent = '忙碌（Job #' + s.activeJobId + '）'; badge.className = 'badge busy'; }
    else if (s.subInitBusy) { badge.textContent = 'Submodule 初始化中'; badge.className = 'badge busy'; }
    else if (s.activeValidations) { badge.textContent = '連線正常（驗證 ' + s.activeValidations + ' 筆）'; badge.className = 'badge busy'; }
    else { badge.textContent = '連線正常'; badge.className = 'badge ok'; }
  } catch (e) {
    badge.textContent = '伺服器未回應'; badge.className = 'badge err';
  }
}
setInterval(pollState, 3000);
pollState();

// ---------- Job 面板 ----------
let currentJob = null;
let logCursor = 0;
let pollTimer = null;

function jobTitle(kind) {
  return { 'sync-preview': '預覽差異', 'sync-apply': '執行同步', fetch: 'Fetch Origin', worktree: '建立 Worktree' }[kind] || kind;
}

function resultText(j) {
  const r = j.result;
  if (!r) return '';
  if (j.kind === 'sync-preview') return '預覽完成：共 ' + (r.totalAdd + r.totalUpdate) + ' 筆異動（下方表格）';
  if (j.kind === 'sync-apply') {
    let t = '已套用 ' + (r.applied || 0) + ' 筆 Ref';
    if (r.conflictSkipped) t += '；衝突略過 ' + r.conflictSkipped + ' 筆';
    if (r.conflicts && r.conflicts.length) t += '\n衝突明細：\n  ' + r.conflicts.slice(0, 20).join('\n  ');
    if (r.skippedSubmodules && r.skippedSubmodules.length) t += '\n跳過的 Submodule：\n  ' + r.skippedSubmodules.join('\n  ');
    if (r.failed && r.failed.length) t += '\n失敗：\n  ' + r.failed.join('\n  ');
    return t;
  }
  if (j.kind === 'fetch') {
    let t = '完成 ' + j.done + '/' + j.total + ' 個 Repo';
    if (r.failed && r.failed.length) t += '\n失敗：\n  ' + r.failed.join('\n  ');
    return t;
  }
  if (j.kind === 'worktree') return '已建立 Worktree：' + (r.target || '') + '\nBranch：' + (r.branch || '');
  return '';
}

function showJobPanel() {
  $('job-panel').classList.remove('collapsed');
  $('job-dot').classList.add('hidden');
}

// ---------- 面板徽章狀態機 ----------
// 一般單一工作：待機 -> 等待指令中（送出/驗證中）-> 進行中 -> 完成/失敗。
// 一鍵同步跨「預覽＋套用」兩個工作：jobFlow=true 期間單個工作 Done 不寫「完成」，
// 改寫「等待指令中」，整個流程真正結束才落終態（pollJob 與 oneclick finally 合力）。
let jobFlow = false;
let flowLastState = null;   // 本流程最後一個結束工作的狀態（Done/Failed），供流程收尾決定徽章
function setJobBadge(text, cls) {
  const st = $('job-state');
  st.textContent = text;
  st.className = 'badge ' + cls;
  // 小圓點只在寫入終態且面板收合時亮；進入任何非終態代表新工作開始，先滅掉舊圓點
  if (cls !== 'ok' && cls !== 'err') { $('job-dot').classList.add('hidden'); return; }
  if ($('job-panel').classList.contains('collapsed')) $('job-dot').classList.remove('hidden');
}

// ---------- Log 自動捲動 ----------
// 注意：真正的捲動容器是 #job-body（overflow:auto），#job-log（pre）本身不會捲動。
function logNearBottom() {
  const body = $('job-body');
  // 面板收合（或尚未排版）時 clientHeight=0，一律視為「已在底部」，避免誤判成「往上翻」
  if ($('job-panel').classList.contains('collapsed') || body.clientHeight === 0) return true;
  return body.scrollHeight - body.scrollTop - body.clientHeight < 40;
}
function scrollLogToBottom() {
  const body = $('job-body');
  body.scrollTop = body.scrollHeight;
  $('job-latest').classList.add('hidden');
}
$('job-body').addEventListener('scroll', function () {
  if (logNearBottom()) $('job-latest').classList.add('hidden');
});
$('job-latest').addEventListener('click', function (ev) {
  ev.stopPropagation();
  scrollLogToBottom();
});

// watchJob 回傳 Promise：工作結束（Done/Failed）時以最終 job 物件 resolve（一鍵同步需要串接）
let jobWaiters = {};
let viewMode = 'live';          // 'live' 即時追蹤 | 'hist' 歷史唯讀瀏覽
let lastWatchedJobId = null;    // 最近一次追蹤的工作（返回即時時重現）
let pollGen = 0;                // poll 代數：切換追蹤/進出歷史時 ++，作廢進行中的遲到回應
let histReqSeq = 0;             // 歷史彈窗/歷史 log 請求序，快速連點只採最新一次

function watchJob(jobId) {
  if (viewMode === 'hist') exitHistView();   // 新工作進來：自動退出歷史瀏覽
  pollGen++;
  currentJob = jobId;
  lastWatchedJobId = jobId;
  logCursor = 0;
  polling = false;
  $('job-log').textContent = '';
  $('job-latest').classList.add('hidden');
  $('job-result').classList.add('hidden');
  $('job-title').textContent = '工作面板';
  setJobBadge('進行中', 'busy');   // 立即清掉上一輪殘留徽章；面板展開與否由使用者決定，不再自動展開
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(pollJob, 600);
  pollJob();
  return new Promise(function (resolve) { jobWaiters[jobId] = resolve; });
}

let polling = false;   // 防重入：伺服器忙碌時回應變慢，避免兩次 pollJob 交錯 append 同一批 log
async function pollJob() {
  if (!currentJob || polling) return;
  const gen = pollGen;
  polling = true;
  try {
    const res = await fetch('/api/jobs?id=' + currentJob + '&cursor=' + logCursor);
    if (gen !== pollGen) return;   // 等待期間已切換追蹤或進入歷史：丟棄回應
    if (!res.ok) return;
    const j = await res.json();
    if (gen !== pollGen || currentJob !== j.id) return;   // 已切到別的工作，丟棄遲到的回應
    // 歷史瀏覽中：徽章與進度仍屬即時工作、背景照常更新；標題與 log 顯示歷史內容，不動
    if (viewMode === 'live') {
      $('job-title').textContent = '#' + j.id + ' ' + jobTitle(j.kind);
      if (j.log && j.log.length) {
        const stick = $('job-autoscroll').checked && logNearBottom();
        j.log.forEach(function (l) { $('job-log').textContent += l.m + '\n'; });
        if (stick) {
          scrollLogToBottom();
        } else if ($('job-autoscroll').checked) {
          // 使用者往上翻舊 log：不硬拉捲動，改顯示「到最新」按鈕
          $('job-latest').classList.remove('hidden');
        }
      }
    }
    logCursor = j.next;
    $('job-progress').max = Math.max(j.total, 1);
    $('job-progress').value = j.done;
    if (j.state === 'Running') { setJobBadge('進行中', 'busy'); }
    if (j.state === 'Done') {
      // flowLastState 只認同步流程的兩種工作：其他 kind 即使插在中途結束也不影響流程終態
      if (j.kind === 'sync-preview' || j.kind === 'sync-apply') flowLastState = 'Done';
      // 一鍵同步中途：還有一個工作要接續，先顯示「等待指令中」，終態留給流程結尾
      if (jobFlow) setJobBadge('等待指令中', 'busy'); else setJobBadge('完成', 'ok');
      finishJob(j);
    }
    if (j.state === 'Failed') {
      if (j.kind === 'sync-preview' || j.kind === 'sync-apply') { flowLastState = 'Failed'; jobFlow = false; }
      setJobBadge('失敗', 'err'); finishJob(j);
    }
  } catch (e) { /* 暫時斷線，下一輪再試 */ }
  finally { polling = false; }
}

function finishJob(j) {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  currentJob = null;
  const box = $('job-result');
  const t = resultText(j);
  if (t && viewMode === 'live') { box.textContent = t; box.classList.remove('hidden'); }
  if (viewMode === 'hist') $('job-progress').style.visibility = 'hidden';   // 工作已結束：歷史視圖不留進度列
  if (j.kind === 'sync-preview' && j.state === 'Done' && j.result) {
    renderPreview(j.id, j.result);
  }
  const w = jobWaiters[j.id];
  if (w) { delete jobWaiters[j.id]; w(j); }
}

$('job-head').addEventListener('click', function (ev) {
  if (ev.target.tagName === 'PROGRESS' || ev.target.closest('progress')) return;
  if (ev.target.closest('.autoscroll-chk') || ev.target.closest('label')) return;   // 點自動捲動開關不收合面板
  if (ev.target.closest('#job-history') || ev.target.closest('#job-live')) return;  // 歷史／返回按鈕不觸發收合
  const panel = $('job-panel');
  panel.classList.toggle('collapsed');
  $('job-toggle').innerHTML = panel.classList.contains('collapsed') ? ICONS.chevronUp : ICONS.chevronDown;
  if (!panel.classList.contains('collapsed')) $('job-dot').classList.add('hidden');   // 展開即視為已看過結果
  // 展開時補捲一次：收合期間 append 的 log 不會觸發視覺捲動
  if (!panel.classList.contains('collapsed') && $('job-autoscroll').checked) scrollLogToBottom();
});

// ---------- Log 面板高度拖拉 ----------
(function initResizer() {
  const panel = $('job-panel');
  const grip = $('job-resizer');
  const KEY = 'grm.jobH';
  function clampH(px) { return Math.max(120, Math.min(px, Math.round(window.innerHeight * 0.8))); }
  function applyH(px) {
    if (px == null) panel.style.removeProperty('--job-h');
    else panel.style.setProperty('--job-h', clampH(px) + 'px');
  }
  function currentH() {
    const v = parseFloat(getComputedStyle($('job-body')).height);
    return (v > 0 && !isNaN(v)) ? v : 260;
  }
  const saved = parseInt(localStorage.getItem(KEY), 10);
  if (saved > 0) applyH(saved);
  let dragging = false, startY = 0, startH = 0;
  function onMove(ev) {
    if (!dragging) return;
    applyH(startH + (startY - ev.clientY));   // 往上拖＝變高
  }
  function onUp() {
    if (!dragging) return;
    dragging = false;
    grip.classList.remove('dragging');
    document.body.classList.remove('resizing');
    document.removeEventListener('mousemove', onMove);
    document.removeEventListener('mouseup', onUp);
    localStorage.setItem(KEY, String(Math.round(currentH())));
  }
  grip.addEventListener('mousedown', function (ev) {
    ev.preventDefault();
    dragging = true;
    startY = ev.clientY;
    startH = currentH();
    grip.classList.add('dragging');
    document.body.classList.add('resizing');
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  });
  grip.addEventListener('dblclick', function () {   // 雙擊還原預設高度
    localStorage.removeItem(KEY);
    applyH(null);
  });
  window.addEventListener('resize', function () {   // 視窗變小時重新夾限
    if (panel.style.getPropertyValue('--job-h')) applyH(currentH());
  });
})();

// ---------- 歷史紀錄 ----------
const HIST_KINDS = { 'sync-preview': '預覽', 'sync-apply': '套用', fetch: 'Fetch', worktree: 'Worktree' };

function histSummaryText(it) {
  const parts = [];
  if (it.kind === 'sync-preview') {
    parts.push('新增 ' + (it.totalAdd || 0) + '、更新 ' + (it.totalUpdate || 0) + '、衝突略過 ' + (it.totalConflict || 0));
  } else if (it.kind === 'sync-apply') {
    parts.push('套用 ' + (it.applied || 0) + ' 筆');
    if (it.failedCount) parts.push('失敗 ' + it.failedCount);
    if (it.conflictSkipped) parts.push('衝突略過 ' + it.conflictSkipped);
    if (it.skippedCount) parts.push('跳過 Submodule ' + it.skippedCount);
  } else if (it.kind === 'fetch') {
    parts.push('Repo ' + (it.targets || 0) + ' 個');
    if (it.failedCount) parts.push('失敗 ' + it.failedCount);
  } else if (it.kind === 'worktree') {
    if (it.target) parts.push(it.target);
    if (it.branch) parts.push('Branch：' + it.branch);
  }
  if (it.error) parts.push('錯誤：' + it.error);
  return parts.join('　');
}

function histMetaTitle(it) {
  const m = it.meta || {};
  if (it.kind === 'fetch') return (m.repoA || '') + (m.repoB ? '\nB：' + m.repoB : '');
  if (it.kind === 'worktree') return (m.source || '') + '\nBranch：' + (m.branch || '');
  let t = m.src || '';
  (m.dsts || []).forEach(function (d) { t += '\n-> ' + d; });
  return t;
}

function histLoad() {
  const seq = ++histReqSeq;
  const list = $('hist-list');
  list.innerHTML = '<div class="fm-empty">載入中…</div>';
  fetch('/api/jobs/history').then(function (res) { return res.json(); }).then(function (d) {
    if (seq !== histReqSeq) return;   // 快速連點：只採最新一次回應
    const items = (d && d.items) || [];
    list.innerHTML = '';
    if (!items.length) { list.innerHTML = '<div class="fm-empty">尚未有結束的工作紀錄。</div>'; return; }
    items.forEach(function (it) {
      const div = document.createElement('div');
      div.className = 'hist-item';
      div.title = histMetaTitle(it);
      const stCls = it.state === 'Done' ? 'ok' : (it.state === 'Failed' ? 'err' : 'idle');
      const stTxt = it.state === 'Done' ? '完成' : (it.state === 'Failed' ? '失敗' : it.state);
      div.innerHTML =
        '<span class="hist-id">#' + it.id + '</span>' +
        '<span class="hist-kind">' + esc(HIST_KINDS[it.kind] || it.kind) + '</span>' +
        '<span class="badge hist-badge ' + stCls + '">' + stTxt + '</span>' +
        '<span class="hist-when">' + esc(String(it.endedAt || '').slice(5)) + '</span>' +
        '<span class="hist-sum" style="grid-column:2/-1">' + esc(histSummaryText(it)) + '</span>';
      div.addEventListener('click', function () {
        if (enterHistView(it.id)) histClose();
      });
      list.appendChild(div);
    });
  }).catch(function () {
    if (seq !== histReqSeq) return;
    list.innerHTML = '<div class="fm-empty">讀取歷史紀錄失敗（伺服器未回應）。</div>';
  });
}
function histOpen() { $('hist-modal').classList.remove('hidden'); histLoad(); }
function histClose() { $('hist-modal').classList.add('hidden'); }
$('job-history').addEventListener('click', function (ev) { ev.stopPropagation(); histOpen(); });
$('hist-close').addEventListener('click', histClose);
$('hist-refresh').addEventListener('click', histLoad);
$('hist-modal').addEventListener('click', function (ev) { if (ev.target === this) histClose(); });

// 歷史唯讀瀏覽：即時工作照常背景 poll（徽章／進度持續更新，一鍵同步的 await 不受影響），
// 面板改顯示該筆歷史 log；歷史狀態寫進標題，徽章保留給即時工作。
function enterHistView(id) {
  viewMode = 'hist';   // pollJob 依此旗跳過標題/log 寫入
  const seq = ++histReqSeq;
  fetch('/api/jobs/history/log?id=' + encodeURIComponent(id)).then(function (res) {
    if (!res.ok) return res.text().then(function (t) { throw new Error(t || ('HTTP ' + res.status)); });
    return res.json();
  }).then(function (h) {
    if (viewMode !== 'hist' || seq !== histReqSeq) return;
    $('job-log').textContent = (h.log || []).join('\n');
    const stTxt = h.state === 'Done' ? '完成' : (h.state === 'Failed' ? '失敗' : h.state);
    $('job-title').textContent = '歷史 #' + h.id + ' ' + jobTitle(h.kind) + '（' + stTxt + '）';
    // 進度列屬於即時工作：有工作在跑就照顯示，沒有才用 visibility 收起（保留版面空間不跳位）
    $('job-progress').style.visibility = (currentJob != null) ? '' : 'hidden';
    $('job-latest').classList.add('hidden');
    $('job-result').classList.add('hidden');
    $('job-body').classList.add('hist-view');
    $('job-live').classList.remove('ghost');
    showJobPanel();
    $('job-body').scrollTop = 0;
  }).catch(function (e) {
    if (seq !== histReqSeq) return;
    alert('讀取歷史 Log 失敗：' + e.message);
    exitHistView();
  });
  return true;
}
$('job-live').addEventListener('click', function (ev) { ev.stopPropagation(); exitHistView(); });

function exitHistView() {
  if (viewMode !== 'hist') return;
  viewMode = 'live';
  pollGen++;
  $('job-body').classList.remove('hist-view');
  $('job-live').classList.add('ghost');
  $('job-progress').style.visibility = '';
  const id = (currentJob != null) ? currentJob : lastWatchedJobId;
  if (id == null) {
    $('job-log').textContent = '';
    $('job-title').textContent = '工作面板';
    return;
  }
  // 重抓整份 log 與狀態；若該工作還在跑則繼續 poll
  currentJob = id;
  logCursor = 0;
  $('job-log').textContent = '';
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(pollJob, 600);
  pollJob();
}

// ---------- Repo 驗證燈 ----------
// 燈嵌入路徑框右內緣：空=未驗證、轉圈=驗證中、綠勾=通過（點綠勾展開明細）、紅叉=失敗（錯誤顯示於框下）。
// 觸發時機：Enter、blur（路徑與上次驗證值不同才驗）、選資料夾完成。打字途中一律不發請求。
var VB_SPIN = '<svg class="ic spin" viewBox="0 0 24 24" width="15" height="15"><path d="M21 12a9 9 0 1 1-6.22-8.56"/></svg>';

function vbSetStatus(input, status, opts) {
  const s = input._vb;
  s.status = status;
  if (opts) {
    if ('path' in opts) s.path = opts.path;
    if ('summary' in opts) s.summary = opts.summary;
    if ('err' in opts) s.err = opts.err;
    if ('extra' in opts) s.extra = opts.extra;
  }
  vbRender(input);
}

function vbDetailHtml(summary) {
  const sm = summary.submodules || { total: 0, initialized: 0 };
  let line = '分支: ' + esc(summary.branch) + '　origin: ' + esc(summary.origin || '(無)') + '\n';
  line += '未提交變更: ' + summary.dirty + ' 檔　Submodule: ' + sm.initialized + '/' + sm.total + ' 已初始化';
  return line;
}

function vbRender(input) {
  const s = input._vb;
  if (!s) return;
  const b = s.btn;
  b.classList.remove('hidden', 'ok', 'bad', 'busy');
  b.title = '';
  const v = input.value.trim();
  const dirty = v !== s.path;   // 打字中：路徑與已驗證值不同
  if (!v || s.status === 'empty') {
    // 空白路徑：不顯示燈，明細清空
    b.classList.add('hidden');
    b.innerHTML = '';
    if (s.sumEl) s.sumEl.innerHTML = '';
    return;
  }
  if (s.status === 'ok' && dirty) {
    // 改了路徑尚未重新驗證：先把綠燈收掉，避免誤導；明細收合，只留 origin 警告
    b.classList.add('hidden');
    b.innerHTML = '';
    vbPaintSummary(input);
    return;
  }
  if (s.status === 'checking') {
    b.classList.add('busy'); b.innerHTML = VB_SPIN; b.title = '驗證中…';
    return;   // 保留舊明細
  }
  if (s.status === 'ok') {
    b.classList.remove('hidden'); b.classList.add('ok'); b.innerHTML = ICONS.check;
    b.title = s.expanded ? '收合 Repo 明細' : '展開 Repo 明細';
    vbPaintSummary(input);
    return;
  }
  if (s.status === 'bad') {
    b.classList.remove('hidden'); b.classList.add('bad'); b.innerHTML = ICONS.x;
    b.title = '驗證失敗：' + s.err;
    if (s.sumEl) s.sumEl.innerHTML = '<span class="bad">' + ICONS.x + ' ' + esc(s.err) + '</span>';
  }
}

// 明細預設收合：只保留額外警告（origin 不同等同步行訊）；點綠勾展開四行明細
function vbPaintSummary(input) {
  const s = input._vb;
  if (!s.sumEl) return;
  if (s.expanded && s.summary) {
    s.sumEl.innerHTML = vbDetailHtml(s.summary) + (s.extra || '');
  } else {
    s.sumEl.innerHTML = s.extra || '';
  }
}

// group: 'sync-src'（驗證時連同所有目的 Repo 一次更新）| 'sync-dst' | 'plain'
function vbAttach(input, group, sumEl) {
  const host = input.closest('.input-row') || input.closest('.dst-row');
  if (!host) return;
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'vb hidden';
  btn.addEventListener('click', function (ev) {
    ev.preventDefault();
    ev.stopPropagation();
    const s = input._vb;
    if (s && s.status === 'ok') {
      s.expanded = !s.expanded;
      vbRender(input);
    } else if (s && s.status === 'bad') {
      vbValidate(input);   // 紅燈時點燈＝重試
    }
  });
  input.insertAdjacentElement('afterend', btn);
  input._vb = { status: 'empty', path: null, summary: null, err: '', extra: '', expanded: false, btn: btn, sumEl: sumEl || null, group: group || 'plain' };
  const s = input._vb;
  input.addEventListener('input', function () { vbRender(input); });   // 只重畫燈(髒->藏燈)，不發請求
  input.addEventListener('keydown', function (ev) {
    if (ev.key === 'Enter') {
      ev.preventDefault();
      if (s.blurTimer) { clearTimeout(s.blurTimer); s.blurTimer = null; }   // Enter 立即驗證，取消待觸發的 debounce
      vbValidate(input, true);   // Enter＝強制重驗（外部改過 Repo 狀態時不需改路徑繞快取）
    }
  });
  input.addEventListener('blur', function () {
    const v = input.value.trim();
    if (!v) { if (s.status !== 'empty') vbSetStatus(input, 'empty', { path: null }); return; }
    if (v !== s.path) {
      // 300ms debounce：連續在多個輸入框間跳焦點時，穩定後的框才發驗證
      if (s.blurTimer) clearTimeout(s.blurTimer);
      s.blurTimer = setTimeout(function () { s.blurTimer = null; vbValidate(input); }, 300);
    }
  });
}

function vbSrcSummary() {   // 來源框的 summary JSON 快取（供 dst 燈比對 origin）
  const s = $('sync-src')._vb;
  return (s && s.status === 'ok') ? s.summary : null;
}

// snap：送出請求時的 dstRowsWithInputs() 快照。回應抵達時必須確認該列
// 仍存在且路徑未被改動，才把結果套到燈上（避免舊結果套到新值／錯列）。
function vbGroupResult(json, snap) {
  (json.dsts || []).forEach(function (d, i) {
    const row = (snap || [])[i];
    if (!row) return;
    const inp = row.input;
    if (!inp.isConnected || inp.value.trim() !== row.path) return;   // 列已刪或已改值：這筆結果作廢
    const ok = !!(d.summary && d.summary.ok);
    let extra = '';
    if (d.sameCommonDir === true) extra = '\n<span class="warn">' + ICONS.alert + ' 與 A 共用同一個 Git Repository（Worktree），同步沒有意義</span>';
    else if (d.originMatch === false) extra = '\n<span class="warn">' + ICONS.alert + ' 與 A 的 origin URL 不同</span>';
    vbSetStatus(inp, ok ? 'ok' : 'bad', {
      path: row.path, summary: ok ? d.summary : null,
      err: ok ? '' : ((d.summary && d.summary.error) || '不是有效的 Git Repo'),
      extra: extra
    });
  });
}

// 回傳 Promise：同路徑已通過->立即完成；驗證進行中->加入同一個請求；其餘->實際送出驗證
function vbValidate(input, force) {
  const s = input._vb;
  if (!s) return Promise.resolve();
  if (s.blurTimer) { clearTimeout(s.blurTimer); s.blurTimer = null; }   // 已實際送出：取消 debounce 待觸發
  const v = input.value.trim();
  if (!v) { vbSetStatus(input, 'empty', { path: null }); s.pending = null; return Promise.resolve(); }
  // 同路徑不重驗（省大 Repo 幾十秒）；force（Enter／重新驗證鈕）繞過此快取
  if (!force && s.status === 'ok' && s.path === v) return Promise.resolve();
  if (s.status === 'checking' && s.path === v && s.pending) return s.pending; // 加入進行中
  const p = vbDoValidate(input, v).then(function () { if (s.pending === p) s.pending = null; });
  s.pending = p;
  return p;
}

async function vbDoValidate(input, v) {
  const s = input._vb;
  if (s.group === 'sync-dst') {
    // 送出前先擋同路徑：與 A 相同＝彈窗提示；與其他目的列重複＝紅旗（不發請求）
    const clash = dstPathClash(input, v, true);
    if (clash) {
      vbSetStatus(input, 'bad', {
        path: v,
        err: clash === 'src' ? '不能與來源 Repo（A）同一路徑' : '與其他目的 Repo 列同一路徑'
      });
      if (clash === 'src' && !batchValidating) {
        alert('目的 Repo 不能與來源 Repo（A）使用同一路徑，請改為其他 Repo。');
      }
      return;
    }
  }
  vbSetStatus(input, 'checking', { path: v });
  // 送出前先拍目的列快照：dstList 與回應對映都以快照為準，
  // 回應抵達時再逐列確認路徑未變（見 vbGroupResult）
  let snap = null;
  let r;
  try {
    const body = { src: v };
    if (s.group === 'sync-src') {
      snap = dstRowsWithInputs();
      body.dstList = snap.map(function (p) { return p.path; });
    }
    r = await apiPost('/api/validate', body);
  } catch (e) {
    vbSetStatus(input, 'bad', { err: '無法連線至伺服器' });
    return;
  }
  // 等待期間使用者又改了路徑：這次結果作廢，燈退回未驗證（髒狀態本就隱藏），
  // 留 spinner 會永久轉下去；blur/Enter 會對新值再觸發驗證
  if (input.value.trim() !== v) { vbSetStatus(input, 'empty', { path: null }); return; }
  if (r.status !== 200 || !r.json || !r.json.src) {
    vbSetStatus(input, 'bad', { err: (r.text || '驗證失敗').slice(0, 300) });
    return;
  }
  const sum = r.json.src;
  if (!sum.ok) {
    vbSetStatus(input, 'bad', { err: sum.error || '不是有效的 Git Repo' });
    if (s.group === 'sync-src') vbGroupResult(r.json, snap);   // 目的列也要顯示（src 壞了各 dst 仍會被驗證）
    return;
  }
  let extra = '';
  if (s.group === 'sync-dst') {
    // 單獨驗證目的列時，前端直接比對兩邊 origin（資料已在手，省一次 pair 驗證）
    const srcSum = vbSrcSummary();
    if (srcSum && srcSum.origin !== sum.origin) extra = '\n<span class="warn">' + ICONS.alert + ' 與 A 的 origin URL 不同</span>';
  }
  vbSetStatus(input, 'ok', { summary: sum, err: '', extra: extra });
  if (s.group === 'sync-dst') rebuildSubsFromCache();   // 目的集合變了：用各列快取本地重組清單
  if (s.group === 'sync-src') {
    vbGroupResult(r.json, snap);
    markDstPathClashes();   // 來源改成與某目的列同路徑：該列改紅燈（可能原本是綠燈）＋提示
    renderSubChecklist(r.json);
    // sameCommonDir / origin 不同的警告已寫入各目的列的 extra，不彈窗（避免阻塞一鍵同步流程）
  }
}

// 依畫面順序回傳所有非空白目的列（含 input 元素與 summary），與後端 dstList 順序一致
function dstRowsWithInputs() {
  const out = [];
  document.querySelectorAll('#sync-dst-rows .dst-row').forEach(function (row) {
    const input = row.querySelector('input');
    const v = input.value.trim();
    if (v) out.push({ path: v, input: input, el: row.querySelector('.repo-summary') });
  });
  return out;
}

// ---------- 同路徑檢查（本地同步） ----------
// 正規化後比較（忽略大小寫、斜線方向、尾端斜線），避免「看起來不同、其實同一個資料夾」。
function normPath(p) {
  let v = String(p || '').trim().replace(/\//g, '\\').toLowerCase();
  while (v.length > 2 && v.endsWith('\\')) v = v.slice(0, -1);
  return v;
}
// ensureSyncValidated 批次補驗證時不逐條彈窗（送出端會彙整提示），只標紅燈進失敗清單
let batchValidating = false;
// 一筆目的路徑與誰相同：'src'＝與來源 A　'dup'＝與其他目的列重複　''＝正常
// allRows=true（實際驗證那條列時）：與「任何」其他列相同都算，最後造成重複的那條標紅；
// allRows=false（批次掃描）：只與更前面的列比較，重複對只標後出現的一條、保留一條可用。
function dstPathClash(input, v, allRows) {
  const k = normPath(v);
  if (!k) return '';
  if (normPath($('sync-src').value) === k) return 'src';
  const rows = document.querySelectorAll('#sync-dst-rows .dst-row');
  for (let i = 0; i < rows.length; i++) {
    const el = rows[i].querySelector('input');
    if (el === input) continue;
    if (!allRows && i > Array.prototype.indexOf.call(rows, input)) continue;   // 順序模式只看更前面的列
    if (normPath(el.value) === k) return 'dup';
  }
  return '';
}
// 依目前來源值重掃所有目的列：與 A 同路徑→紅燈＋彈窗提示；B 列彼此重複→後列紅燈（不彈窗）。
// 回傳與 A 同路徑的清單。來源驗證通過後與批次補驗證前都會呼叫。
function markDstPathClashes() {
  const msgs = [];
  dstRowsWithInputs().forEach(function (r) {
    const clash = dstPathClash(r.input, r.path);
    if (!clash) return;
    vbSetStatus(r.input, 'bad', {
      path: r.path,
      err: clash === 'src' ? '不能與來源 Repo（A）同一路徑' : '與其他目的 Repo 列同一路徑'
    });
    if (clash === 'src') msgs.push(r.path);
  });
  if (msgs.length && !batchValidating) {
    alert('以下目的 Repo 與來源 Repo（A）同一路徑，不能同步，請改為其他 Repo：\n' +
      msgs.map(function (m) { return ' - ' + m; }).join('\n'));
  }
  return msgs;
}

// 同步頁：把所有髒/未驗證的框依序補驗證；回傳失敗原因清單（空＝全部通過）
async function ensureSyncValidated() {
  const bad = [];
  const inputs = [$('sync-src')].concat(dstRowsWithInputs().map(function (r) { return r.input; }));
  batchValidating = true;   // 同路徑等問題只標紅燈進失敗清單，不逐條彈窗
  try {
    // 先全列掃描：兩條早已驗證通過的列事後被改成互相重複時也要抓出（只標後出現者）
    markDstPathClashes();
    for (let i = 0; i < inputs.length; i++) {
      const inp = inputs[i];
      const v = inp.value.trim();
      if (!v) continue;
      await vbValidate(inp);   // 已通過->立即返回；進行中->加入；髒/失敗->送出
      const t = inp._vb;
      if (t.status !== 'ok' || t.path !== v) bad.push(v + '：' + (t.err || '驗證未通過'));
    }
  } finally {
    batchValidating = false;
  }
  return bad;
}

// ---------- Submodule 勾選（只影響本地同步） ----------
function subsListReady() { return !$('sync-subs-details').classList.contains('hidden'); }
function checkedSubPaths() {
  return Array.prototype.slice.call(document.querySelectorAll('#sync-subs-list input[type=checkbox]'))
    .filter(function (cb) { return cb.checked; })
    .map(function (cb) { return cb.dataset.path; });
}
function invalidatePreview() {
  if (previewJobId != null) {
    previewJobId = null;
    $('sync-apply').disabled = true;
    $('sync-apply').textContent = '執行同步（預覽已失效，請重新預覽）';
    $('sync-apply').classList.remove('danger');   // 停用狀態用中性灰，紅色只留給可執行時
    $('sync-apply').classList.add('secondary');
  }
}
// 合併來源與所有目的列的 Submodule 初始化狀態 -> { key: { path, initA, initB } }
// （renderSubChecklist 與送前輕量比對 subsMapDiffers 共用）
function buildSubsMap(json) {
  const map = {};
  function addAll(paths, side) {
    (paths || []).forEach(function (p) {
      const k = p.path.toLowerCase();
      if (!map[k]) map[k] = { path: p.path, initA: false, initB: false };
      map[k][side] = !!p.initialized;
    });
  }
  addAll(json.src && json.src.submodulePaths, 'initA');
  if (json.dsts && json.dsts.length) {
    json.dsts.forEach(function (d) { addAll(d.summary && d.summary.submodulePaths, 'initB'); });
  } else {
    addAll(json.dst && json.dst.submodulePaths, 'initB');
  }
  return map;
}
function renderSubChecklist(json) {
  const det = $('sync-subs-details');
  const box = $('sync-subs-list');
  const map = buildSubsMap(json);
  subsRenderMap = map;   // 記下這份清單對應的狀態（送前輕量比對的基準）
  const keys = Object.keys(map).sort();
  if (!keys.length) {
    det.classList.add('hidden');
    $('subs-toolbar').classList.add('hidden');
    box.innerHTML = '<span class="fm-empty">兩邊都沒有 Submodule。</span>';
    invalidatePreview();
    return;
  }
  det.classList.remove('hidden');
  // 不強制展開：清單保持收合，統計已寫在 summary；使用者展開後重新驗證也維持他的選擇
  $('subs-toolbar').classList.remove('hidden');
  box.innerHTML = '';
  const recurseOn = $('sync-recurse').checked;
  const bothCount = keys.filter(function (k) { return map[k].initA && map[k].initB; }).length;
  if (!bothCount) {
    const tip = document.createElement('div');
    tip.className = 'subs-skip-tip';
    tip.textContent = '目前沒有兩邊皆已初始化的 Submodule，遞迴同步不會處理任何一顆' +
      (keys.some(function (k) { return map[k].initA && !map[k].initB; }) ? '；B 側可點右方「從 A 初始化」處理' : '');
    box.appendChild(tip);
  }
  // 「從 A 初始化」需明確的單一目的 Repo；多目的時不顯示（不知道要初始化哪邊）
  const singleDst = dstRowsWithInputs().length === 1;
  keys.forEach(function (k) {
    const it = map[k];
    const both = it.initA && it.initB;
    const label = document.createElement('label');
    label.className = 'sub-item' + (both ? '' : ' disabled');
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = both;                 // 預設全選「兩邊皆可處理」者
    cb.disabled = !both || !recurseOn; // 未初始化或已關遞迴：不可勾
    if (!both) cb.dataset.uninit = '1';
    cb.dataset.path = it.path;
    cb.addEventListener('change', function () { invalidatePreview(); updateSubCount(); });
    const name = document.createElement('span');
    name.textContent = ' ' + it.path + ' ';
    label.appendChild(cb);
    label.appendChild(name);
    if (!both) {
      const tag = document.createElement('span');
      tag.className = 'git-tag warn-tag';
      tag.textContent = (!it.initA ? 'A' : 'B') + ' 未初始化（會略過）';
      label.appendChild(tag);
    }
    if (it.initA && !it.initB && singleDst) {
      const ib = document.createElement('button');
      ib.type = 'button';
      ib.className = 'btn small secondary sub-init-btn';
      ib.textContent = '從 A 初始化';
      ib.title = '以 A 的本機複製在 B 初始化這顆 Submodule（不需要網路；完成後自動重新驗證）';
      ib.addEventListener('click', function (ev) { ev.preventDefault(); ev.stopPropagation(); subInitFromA(it.path, ib); });
      label.appendChild(ib);
    }
    box.appendChild(label);
  });
  updateSubCount();
  invalidatePreview();
  applyPendingSubSelection();
}

// ---------- Submodule 清單：本地重建（免重複整趟驗證） ----------
// 清單資料其實都已在各驗證燈的快取裡：來源回應含 A 側 submodulePaths，
// 每條目的列的驗證回應含 B 側。目的列增／刪／換路徑後直接用快取在本地重組，
// 不再對來源補跑整趟完整驗證。快取不齊（例如剛改路徑尚未重驗）時維持原清單；
// 工具外動過初始化造成的落差，由送出前的 subsLightCheck 輕量比對補上。
function subsCacheJson() {
  const src = $('sync-src');
  if (!src._vb || src._vb.status !== 'ok' || src._vb.path !== src.value.trim()) return null;
  const pairs = dstRowsWithInputs();
  if (!pairs.length) return null;
  const dsts = [];
  for (let i = 0; i < pairs.length; i++) {
    const iv = pairs[i].input._vb;
    if (!iv || iv.status !== 'ok' || iv.path !== pairs[i].path) return null;
    dsts.push({ summary: iv.summary });
  }
  return { src: src._vb.summary, dsts: dsts };
}
// 重組清單並保留使用者勾選：舊的「可處理」項目沿用原勾選；新增者可處理者維持
// renderSubChecklist 預設（勾選）；轉為未初始化者自然落到略過列。
function rebuildSubsFromJson(j) {
  const prevChecked = {}, prevKnown = {};
  subCbs().forEach(function (cb) {
    const k = cb.dataset.path.toLowerCase();
    prevKnown[k] = true;
    prevChecked[k] = cb.checked;
  });
  renderSubChecklist(j);
  subCbs().forEach(function (cb) {
    if (cb.dataset.uninit === '1') return;
    const k = cb.dataset.path.toLowerCase();
    if (prevKnown[k]) cb.checked = !!prevChecked[k];
  });
  updateSubCount();
}
function rebuildSubsFromCache() {
  if (!subsListReady()) return;   // 清單尚未建立：等來源驗證自然產生
  const j = subsCacheJson();
  if (j) rebuildSubsFromJson(j);
}

// ---------- 送出前輕量比對（搭配本地重建） ----------
// 問後端各 Repo「目前」的 Submodule 初始化旗標：只跑 git submodule status，
// 不掃分支與工作目錄，單趟百毫秒級。與畫面清單不一致時自動重建並提示。
// 查詢失敗不阻擋送出：後端預覽／套用時仍會逐顆即時判定，最多多列一條「跳過」。
let subsRenderMap = null;   // 畫面清單渲染時的合併狀態（比對基準）
async function subsLightCheck() {
  if (!subsListReady()) return;
  const srcV = $('sync-src').value.trim();
  const rows = dstRowsWithInputs();
  if (!srcV || !rows.length) return;
  let r;
  try {
    r = await apiPost('/api/subs/status', { paths: [srcV].concat(rows.map(function (x) { return x.path; })) });
  } catch (e) { return; }
  if (r.status !== 200 || !r.json || !Array.isArray(r.json.items)) return;
  if (r.json.items.length < 1 + rows.length) return;               // 回應不齊：維持現況
  if (r.json.items.some(function (it) { return !it.ok; })) return;  // 有 Repo 問不到：維持現況
  const j = {
    src: { submodulePaths: r.json.items[0].subs || [] },
    dsts: r.json.items.slice(1).map(function (it) { return { summary: { submodulePaths: it.subs || [] } }; })
  };
  if (!subsMapDiffers(buildSubsMap(j))) return;
  rebuildSubsFromJson(j);
  profileHint('Submodule 初始化狀態有變動，勾選清單已自動更新');
}
// 比對「新查到的狀態」與「畫面清單渲染時」：路徑集合與各別 init 旗標全同才算沒變
function subsMapDiffers(now) {
  const old = subsRenderMap || {};
  const keys = Object.keys(now);
  if (keys.length !== Object.keys(old).length) return true;
  return keys.some(function (k) {
    const a = old[k];
    return !a || a.initA !== now[k].initA || a.initB !== now[k].initB;
  });
}

// ---------- Submodule：在 B 從 A 初始化（後端子行程執行，本地複製） ----------
async function subInitFromA(relPath, btn) {
  const src = $('sync-src').value.trim();
  const rows = dstRowsWithInputs();
  if (!src || rows.length !== 1) { alert('請確認來源與目的 Repo：「從 A 初始化」僅支援單一目的 Repo 的情境'); return; }
  if (!confirm('要在 B 以 A 的本機複製初始化「' + relPath + '」嗎？\n完成後這顆 Submodule 的 origin 會暫時指向 A 的本機路徑。')) return;
  const old = btn.textContent;
  btn.disabled = true;
  btn.textContent = '初始化中…';
  let ok = false;
  let stale = false;   // 後端回報畫面狀態過期（已是初始化／找不到等）：自動重驗自愈
  try {
    const r = await apiPost('/api/submodule/init-from-a', { src: src, dst: rows[0].path, path: relPath });
    if (r.status === 200 && r.json && r.json.ok) ok = true;
    else if (r.status === 409) alert('目前有工作在進行中，無法初始化，請等它結束後再試');
    else {
      const msg = String((r.json && (r.json.message || r.json.error)) || r.text || ('HTTP ' + r.status)).slice(0, 500);
      alert('初始化失敗：' + msg);
      stale = msg.indexOf('重新驗證') >= 0;
    }
  } catch (e) {
    alert('初始化請求中斷：' + e.message + '\n伺服器可能仍在背景進行，請看頂部狀態徽章；結束前請先不要重複點擊。');
  }
  if (ok || stale) {
    // 強制重驗來源列（請求自帶 dstList，目的列燈與清單一併更新）；
    // 清單重畫後此按鈕自然消失（已初始化），或從舊清單取得新狀態
    await vbValidate($('sync-src'), true);
  } else {
    btn.disabled = false;
    btn.textContent = old;
  }
}

// 載入設定檔後，等清單重畫完成再把 Submodule 勾選還原（profile 模組設定 pending）
function applyPendingSubSelection() {
  if (!pendingProfileSubs) return;
  const want = {};
  pendingProfileSubs.forEach(function (p) { want[String(p).toLowerCase()] = true; });
  subCbs().forEach(function (cb) {
    if (cb.disabled) return;
    cb.checked = !!want[String(cb.dataset.path).toLowerCase()];
  });
  pendingProfileSubs = null;
  updateSubCount();
}
// 關閉「遞迴處理 Submodule」時，勾選清單整體暫時不可勾
$('sync-recurse').addEventListener('change', function () {
  const on = this.checked;
  document.querySelectorAll('#sync-subs-list input[type=checkbox]').forEach(function (cb) {
    cb.disabled = !on || cb.dataset.uninit === '1';
  });
  updateSubCount();
  invalidatePreview();
});

// ---------- Submodule 全選／清空 ----------
function subCbs() {
  return Array.prototype.slice.call(document.querySelectorAll('#sync-subs-list input[type=checkbox]'));
}
// 可勾選＝兩邊都已初始化（uninit 者永遠略過）；遞迴關閉時全部不可選
function updateSubCount() {
  const on = $('sync-recurse').checked;
  const cbs = subCbs();
  const eligible = cbs.filter(function (cb) { return cb.dataset.uninit !== '1'; });
  const uninit = cbs.length - eligible.length;
  const sel = eligible.filter(function (cb) { return cb.checked; }).length;
  $('subs-count').textContent = on ? ('已選 ' + sel + ' / ' + eligible.length) : '遞迴已關閉，全部略過';
  // 標題列統計：清單收合時也能一眼看到預設全選／略過數量
  $('subs-sum-count').textContent = on
    ? ('（已選 ' + sel + '／可處理 ' + eligible.length + '、略過 ' + uninit + '）')
    : '（遞迴已關閉，全部略過）';
  const none = !on || !eligible.length;
  $('subs-all').disabled = none || eligible.every(function (cb) { return cb.checked; });
  $('subs-none').disabled = none || sel === 0;
}
$('subs-all').addEventListener('click', function () {
  subCbs().forEach(function (cb) { if (!cb.disabled) cb.checked = true; });
  updateSubCount();
  invalidatePreview();
});
$('subs-none').addEventListener('click', function () {
  subCbs().forEach(function (cb) { if (!cb.disabled) cb.checked = false; });
  updateSubCount();
  invalidatePreview();
});
// 「重新驗證」：來源與所有目的 Repo 忽略同路徑快取一次重驗（外部動過 submodule／
// 完成手動初始化後清單沒跟上時用）。來源請求自帶 dstList，一趟更新所有燈與清單。
$('subs-refresh').addEventListener('click', async function () {
  const src = $('sync-src');
  if (!src.value.trim()) { alert('請先輸入來源 Repo 路徑'); return; }
  const btn = this;
  const old = btn.textContent;
  btn.disabled = true;
  btn.textContent = '驗證中…';
  try {
    await vbValidate(src, true);
  } finally {
    btn.disabled = false;
    btn.textContent = old;
  }
});

// ---------- 本地同步（一個來源 -> 多個目的） ----------
let previewJobId = null;
let lastConflicts = {};   // key: "目的序-列序" -> 衝突字串清單，供明細列展開

function addDstRow(value) {
  const wrap = $('sync-dst-rows');
  const row = document.createElement('div');
  row.className = 'dst-row';
  const input = document.createElement('input');
  input.type = 'text';
  input.placeholder = '例：D:\\MyProject_2';
  input.value = value || '';
  input.addEventListener('input', invalidatePreview);
  const browse = document.createElement('button');
  browse.type = 'button';
  browse.className = 'icon-btn browse-btn';
  browse.title = '瀏覽資料夾';
  browse.innerHTML = ICONS.folder;
  browse.addEventListener('click', function () { fmOpenFor(input); });
  const del = document.createElement('button');
  del.type = 'button';
  del.className = 'dst-del';   // 資料夾按鈕右上角的小角標（絕對定位，不佔列寬）
  del.title = '移除這個目的 Repo';
  del.innerHTML = ICONS.x;
  del.addEventListener('click', function () {
    row.remove();
    refreshDstDels();
    invalidatePreview();
    rebuildSubsFromCache();   // 刪列後用剩下各列的快取立即重組清單（免再跑驗證）
    scheduleSaveLast();   // 目的列增刪也要記進「上次設定」
  });
  const sum = document.createElement('div');
  sum.className = 'repo-summary';
  row.appendChild(input);
  row.appendChild(browse);
  row.appendChild(del);
  row.appendChild(sum);
  wrap.appendChild(row);
  vbAttach(input, 'sync-dst', sum);
  refreshDstDels();
  return row;
}
// 只剩一列時隱藏刪除鈕（避免把目的 Repo 刪光）；增／刪列後都要刷新
function refreshDstDels() {
  const rows = document.querySelectorAll('#sync-dst-rows .dst-row');
  const hide = rows.length <= 1;
  rows.forEach(function (row) {
    const del = row.querySelector('.dst-del');
    if (del) del.classList.toggle('hidden', hide);
  });
}
function dstRowPairs() {
  // 依畫面順序回傳 { path, el }（略過空白列，保留對應關係）
  const pairs = [];
  document.querySelectorAll('#sync-dst-rows .dst-row').forEach(function (row) {
    const v = row.querySelector('input').value.trim();
    if (v) pairs.push({ path: v, el: row.querySelector('.repo-summary') });
  });
  return pairs;
}
$('sync-dst-add').addEventListener('click', function () { addDstRow('').querySelector('input').focus(); });
$('sync-src').addEventListener('input', invalidatePreview);
addDstRow('');   // 初始一列空白

// 明細展開／收合（事件委派掛在 per-dst 容器，一次只看一列）
$('sync-per-dst').addEventListener('click', function (ev) {
  const btn = ev.target.closest('.detail-btn');
  if (!btn) return;
  const tr = btn.closest('tr');
  const next = tr.nextElementSibling;
  if (next && next.classList.contains('detail-row')) {   // 收合
    next.remove();
    btn.innerHTML = ICONS.chevronDown;
    return;
  }
  this.querySelectorAll('tr.detail-row').forEach(function (r) { r.remove(); });
  this.querySelectorAll('.detail-btn').forEach(function (b) { b.innerHTML = ICONS.chevronDown; });
  const dr = document.createElement('tr');
  dr.className = 'detail-row';
  dr.innerHTML = '<td colspan="5"><pre class="conf-detail">' +
    (lastConflicts[btn.dataset.key] || []).map(esc).join('\n') + '</pre></td>';
  tr.after(dr);
  btn.innerHTML = ICONS.chevronUp;
});

// ---------- 送出時的視覺回饋（按鈕轉圈＋階段文字） ----------
// 送出當下先收起舊預覽結果，避免新結果產生前新舊混看；
// 進度提示只在按鈕上顯示（曾有全寬「計算差異中…」列與按鈕文字重複，已移除）
function hideStalePreview() {
  $('sync-preview-box').classList.add('hidden');
}
// 按鈕忙碌態：轉圈＋階段文字；clearBtn 還原原本按鈕文字
function setBtnBusy(btn, text) {
  if (!btn.dataset.label) btn.dataset.label = btn.textContent;
  btn.classList.add('busy');
  btn.innerHTML = VB_SPIN + esc(text);
}
function clearBtn(btn) {
  btn.classList.remove('busy');
  btn.innerHTML = esc(btn.dataset.label || btn.textContent);
}

// 送出預覽工作並等完成；回傳 { ok, job }（409/啟動失敗時 ok=false）
async function startPreviewJob() {
  const body = {
    src: $('sync-src').value.trim(),
    dstList: dstRowPairs().map(function (p) { return p.path; }),
    includeOrigin: $('sync-origin').checked,
    includeHeads: $('sync-heads').checked,
    recurse: $('sync-recurse').checked
  };
  if (subsListReady()) body.submodules = checkedSubPaths();   // 有勾選清單時只同步被勾選者
  const r = await apiPost('/api/sync/preview', body);
  if (r.status === 409) { showJobPanel(); setJobBadge('待機', 'idle'); alert('已有工作進行中'); return { ok: false }; }
  if (!r.json || !r.json.jobId) { setJobBadge('待機', 'idle'); alert(r.text || '啟動預覽失敗'); return { ok: false, msg: r.text }; }
  $('sync-apply').disabled = true;
  const job = await watchJob(r.json.jobId);
  return { ok: true, job: job };
}

$('sync-preview').addEventListener('click', async function () {
  const btn = this;
  const src = $('sync-src').value.trim();
  const dsts = dstRowPairs().map(function (p) { return p.path; });
  if (!src || !dsts.length) { alert('請輸入 A 與至少一個 B 的路徑'); return; }
  btn.disabled = true;
  $('sync-oneclick').disabled = true;
  setJobBadge('等待指令中', 'busy');   // 按下立即脫離「待機」：補驗證與排隊都算這段
  try {
    // 預覽前補驗證：髒/未驗證/上次失敗的框先驗證，任一失敗即停止
    hideStalePreview();
    setBtnBusy(btn, '驗證 Repo 中…');
    const bad = await ensureSyncValidated();
    if (bad.length) { setJobBadge('待機', 'idle'); alert('Repo 驗證未通過：\n' + bad.join('\n')); return; }
    setBtnBusy(btn, '檢查 Submodule…');
    await subsLightCheck();   // 工具外動過初始化時自動刷新清單（沒變無感）
    setBtnBusy(btn, '計算差異中…');
    await startPreviewJob();
  } catch (e) {
    // fetch 層異常（例如伺服器進程掛掉）：不留卡在「等待指令中」的徽章
    setJobBadge('待機', 'idle');
    alert('預覽啟動失敗：' + (e && e.message ? e.message : e));
  } finally {
    clearBtn(btn);
    btn.disabled = false;
    $('sync-oneclick').disabled = false;
  }
});

// ---------- 一鍵同步（驗證 -> 預覽 -> 套用） ----------
let oneclickRunning = false;
$('sync-oneclick').addEventListener('click', async function () {
  if (oneclickRunning) return;
  const btn = this;
  const src = $('sync-src').value.trim();
  const dsts = dstRowPairs().map(function (p) { return p.path; });
  if (!src || !dsts.length) { alert('請輸入 A 與至少一個 B 的路徑'); return; }
  oneclickRunning = true;
  btn.disabled = true;
  $('sync-preview').disabled = true;
  // 流程徽章：按下即刻「等待指令中」，跨驗證/預覽/套用全程有效，
  // 中途單一工作 Done 由 pollJob 寫「等待指令中」而非「完成」，最後才落終態
  jobFlow = true;
  flowLastState = null;
  setJobBadge('等待指令中', 'busy');
  try {
    // 1. 補驗證所有髒/未驗證的框
    hideStalePreview();
    setBtnBusy(btn, '驗證 Repo 中…');
    const bad = await ensureSyncValidated();
    if (bad.length) { alert('Repo 驗證未通過，已停止一鍵同步：\n' + bad.join('\n')); return; }
    // 2. 自動預覽（先做輕量 Submodule 比對，工具外動過初始化時自動刷新清單）
    setBtnBusy(btn, '檢查 Submodule…');
    await subsLightCheck();
    setBtnBusy(btn, '計算差異中…');
    const prev = await startPreviewJob();
    if (!prev.ok) return;
    const job = prev.job;
    if (job.state !== 'Done' || !job.result) { alert('預覽工作未正常完成，請看工作面板 Log'); return; }
    const res = job.result;
    const total = (res.totalAdd || 0) + (res.totalUpdate || 0);
    // 3. 無差異 -> 提示後結束，不執行
    if (total === 0) {
      clearBtn(btn);   // 彈窗期間不顯示轉圈
      alert('無需同步：兩邊 Ref 沒有差異。\n（衝突略過 ' + (res.totalConflict || 0) + ' 筆屬固定現象，不會套用）');
      return;
    }
    // 4. origin 不同的目的 Repo -> 先彈窗確認，確定才帶 forceOrigin（action 列已預勾 force 則跳過彈窗）
    let force = false;
    const mism = (res.perDst || []).filter(function (d) { return d.originMismatch && !d.fatal; });
    if (mism.length) {
      if ($('sync-force-always-cb').checked) {
        force = true;
      } else {
        clearBtn(btn);   // 確認彈窗期間不顯示轉圈
        let msg = '以下目的 Repo 的 origin URL 與 A 不同：';
        mism.forEach(function (d) {
          msg += '\n  ' + d.dst + '\n    A：' + (d.originA || '(無)') + '\n    B：' + (d.originB || '(無)');
        });
        msg += '\n\n確定要把它們視為同一來源並強制同步（forceOrigin）嗎？\n（不想每次都確認，可勾選「一鍵同步」右側的 force）';
        if (!confirm(msg)) return;
        force = true;
      }
    }
    // 5. 套用（仍走後端 plan，planStale 防護不變）
    setBtnBusy(btn, '套用中…');
    const ab = { jobId: job.id, forceOrigin: force, dstList: dsts };
    if (subsListReady()) ab.submodules = checkedSubPaths();
    const r = await apiPost('/api/sync/apply', ab);
    if (r.status === 409) { alert('已有工作進行中'); return; }
    if (r.status === 400 && r.json && r.json.error === 'planStale') {
      alert('目的 Repo 清單或 Submodule 勾選與預覽時不一致，請重新預覽。');
      previewJobId = null;
      return;
    }
    if (!r.json || !r.json.jobId) { alert(r.text || '啟動同步失敗'); return; }
    await watchJob(r.json.jobId);
  } finally {
    clearBtn(btn);
    oneclickRunning = false;
    $('sync-oneclick').disabled = false;
    $('sync-preview').disabled = false;
    if (jobFlow) {
      // 流程結束但終態還沒人寫（無差異、使用者取消、被擋在啟動前）：
      // 有跑完過工作寫「完成」，一個工作都沒開始則回「待機」（失敗已由 pollJob 直接寫）
      jobFlow = false;
      if (flowLastState === 'Failed') setJobBadge('失敗', 'err');
      else if (flowLastState === 'Done') setJobBadge('完成', 'ok');
      else setJobBadge('待機', 'idle');
    }
  }
});

function renderPreview(jobId, result) {
  previewJobId = jobId;
  $('sync-preview-box').classList.remove('hidden');
  const perDst = result.perDst || [];
  let skipTotal = 0;
  perDst.forEach(function (d) { skipTotal += (d.skipped || []).length; });
  $('sync-totals').textContent = '合計：' + perDst.length + ' 個目的 Repo　新增 ' + result.totalAdd +
    '、更新 ' + result.totalUpdate + '、衝突略過 ' + result.totalConflict + '、跳過 Submodule ' + skipTotal + ' 個';
  const wrap = $('sync-per-dst');
  wrap.innerHTML = '';
  lastConflicts = {};
  let anyMismatch = false;
  perDst.forEach(function (d, di) {
    const isFatal = !!d.fatal;
    // 非 fatal 者做成 <details>：預設全部收合，標題列（路徑＋統計）可點開看明細
    let html = isFatal
      ? '<div class="dst-section">'
      : '<details class="dst-section">';
    html += (isFatal ? '<div class="dst-summary">' : '<summary class="dst-summary"><span class="chev">' + ICONS.chevronRight + '</span>') +
      ICONS.hardDrive + ' <b>' + esc(d.dst) + '</b>';
    if (d.originMismatch) { anyMismatch = true; html += '　<span class="warn">' + ICONS.alert + ' origin 與 A 不同</span>'; }
    if (isFatal) {
      html += '</div><div class="bad">' + ICONS.x + ' ' + esc(d.fatal) + '（這個目的 Repo 不會執行）</div></div>';
      wrap.insertAdjacentHTML('beforeend', html);
      return;
    }
    html += '　<span class="muted">新增 ' + d.totalAdd + '、更新 ' + d.totalUpdate + '、衝突略過 ' + d.totalConflict + '</span></summary>';
    html += '<div class="tbl-wrap"><table class="tbl"><thead><tr><th>Repo</th><th class="num">新增</th>' +
      '<th class="num">更新</th><th class="num">衝突略過</th><th class="col-detail">明細</th></tr></thead><tbody>';
    (d.entries || []).forEach(function (e, idx) {
      const confs = e.conflicts || [];
      lastConflicts[di + '-' + idx] = confs;
      const key = di + '-' + idx;
      const detail = confs.length
        ? '<button class="icon-btn detail-btn" data-key="' + key + '" title="展開衝突明細（' + confs.length + ' 筆）">' + ICONS.chevronDown + '</button>'
        : '<span class="muted">—</span>';
      html += '<tr><td>' + esc(e.label) + '</td><td class="num">' + e.add + '</td><td class="num">' + e.update +
        '</td><td class="num">' + confs.length + '</td><td class="col-detail">' + detail + '</td></tr>';
    });
    html += '</tbody></table></div>';
    const skipped = d.skipped || [];
    if (skipped.length) {
      html += '<details><summary>' + ICONS.chevronRight + '跳過的 Submodule（' + skipped.length + ' 個）</summary><ul>' +
        skipped.map(function (s) { return '<li>' + esc(s) + '</li>'; }).join('') + '</ul></details>';
    }
    html += '</details>';
    wrap.insertAdjacentHTML('beforeend', html);
  });
  // 「全部收合／全部展開」只在有 2 個以上可收合區塊時出現
  updDstToggleBtn();
  $('sync-force-origin').classList.toggle('hidden', !anyMismatch);
  $('sync-force-origin-cb').checked = false;
  const total = result.totalAdd + result.totalUpdate;
  $('sync-apply').disabled = total === 0;
  const applyBtn = $('sync-apply');
  applyBtn.textContent = total === 0 ? '無需更新' : ('執行同步（' + total + ' 筆）');
  applyBtn.classList.toggle('danger', total > 0);   // 無差異時中性灰，不用警示紅
  applyBtn.classList.toggle('secondary', total === 0);
}

// ---- 預覽結果：目的 Repo 區塊收合 ----
function dstSections() {
  return Array.prototype.slice.call(document.querySelectorAll('#sync-per-dst details.dst-section'));
}
function updDstToggleBtn() {
  const secs = dstSections();
  const btn = $('dst-collapse-all');
  if (secs.length < 2) { btn.classList.add('hidden'); return; }
  btn.classList.remove('hidden');
  const allOpen = secs.every(function (s) { return s.open; });
  btn.textContent = allOpen ? '全部收合' : '全部展開';
}
$('dst-collapse-all').addEventListener('click', function () {
  const secs = dstSections();
  const allOpen = secs.every(function (s) { return s.open; });
  secs.forEach(function (s) { s.open = !allOpen; });
  updDstToggleBtn();
});
// details 的 toggle 事件不冒泡，用 capture 收來自各區塊標題的收合
$('sync-per-dst').addEventListener('toggle', function () { updDstToggleBtn(); }, true);

$('sync-force-origin-cb').addEventListener('change', function () {
  if (previewJobId != null) $('sync-apply').disabled = !this.checked && !document.getElementById('sync-force-origin').classList.contains('hidden');
});

$('sync-apply').addEventListener('click', async function () {
  if (previewJobId == null) return;
  if (oneclickRunning) { alert('一鍵同步進行中，請等它結束'); return; }
  // action 列的 force 勾選（預先同意）與預覽面板內的 forceOrigin 擇一即可
  const force = $('sync-force-always-cb').checked ||
    (!$('sync-force-origin').classList.contains('hidden') && $('sync-force-origin-cb').checked);
  const ab = {
    jobId: previewJobId,
    forceOrigin: force,
    dstList: dstRowPairs().map(function (p) { return p.path; })
  };
  if (subsListReady()) ab.submodules = checkedSubPaths();
  setJobBadge('等待指令中', 'busy');   // 送出前先離開上輪終態（與 help 的徽章說明一致）
  const r = await apiPost('/api/sync/apply', ab);
  if (r.status === 409) { showJobPanel(); setJobBadge('待機', 'idle'); alert('已有工作進行中'); return; }
  if (r.status === 400 && r.json && r.json.error === 'originMismatch') {
    setJobBadge('待機', 'idle');
    let msg = '以下目的 Repo 的 origin URL 與 A 不同：';
    (r.json.mismatchDsts || []).forEach(function (d) { msg += '\n  ' + d; });
    msg += '\nA: ' + r.json.originA + '\nB: ' + r.json.originB + '\n\n請勾選「forceOrigin」再執行。';
    alert(msg);
    return;
  }
  if (r.status === 400 && r.json && r.json.error === 'planStale') {
    setJobBadge('待機', 'idle');
    alert('目的 Repo 清單或 Submodule 勾選與預覽時不一致，請重新預覽。');
    previewJobId = null;
    $('sync-apply').disabled = true;
    return;
  }
  if (!r.json || !r.json.jobId) { setJobBadge('待機', 'idle'); alert(r.text || '啟動同步失敗'); return; }
  $('sync-apply').disabled = true;
  watchJob(r.json.jobId);
});

// ---------- Fetch ----------
$('fetch-start').addEventListener('click', function () {
  if (!$('fetch-a').value.trim()) { alert('請輸入 Repo A 路徑'); return; }
  $('fetch-confirm-bar').classList.remove('hidden');
});
$('fetch-confirm-no').addEventListener('click', function () {
  $('fetch-confirm-bar').classList.add('hidden');
});
$('fetch-confirm-yes').addEventListener('click', async function () {
  $('fetch-confirm-bar').classList.add('hidden');
  if (oneclickRunning) { alert('一鍵同步進行中，請等它結束'); return; }
  setJobBadge('等待指令中', 'busy');   // 送出前先離開上輪終態
  const r = await apiPost('/api/fetch/start', {
    repoA: $('fetch-a').value.trim(),
    repoB: $('fetch-b').value.trim(),
    prune: $('fetch-prune').checked,
    recurse: $('fetch-recurse').checked,
    confirm: true
  });
  if (r.status === 409) { showJobPanel(); setJobBadge('待機', 'idle'); alert('已有工作進行中'); return; }
  if (!r.json || !r.json.jobId) { setJobBadge('待機', 'idle'); alert(r.text || '啟動 Fetch 失敗'); return; }
  watchJob(r.json.jobId);
});

// ---------- Worktree ----------
$('wt-check').addEventListener('click', async function () {
  const r = await apiPost('/api/worktree/check', {
    source: $('wt-source').value.trim(),
    parent: $('wt-parent').value.trim(),
    folderName: $('wt-folder').value.trim(),
    branch: $('wt-branch').value.trim(),
    startingPoint: $('wt-start').value.trim()
  });
  if (!r.json) { alert(r.text || '檢查失敗'); return; }
  $('wt-check-box').classList.remove('hidden');
  $('wt-check-list').innerHTML = (r.json.items || []).map(function (it) {
    return '<li class="' + (it.ok ? 'ok' : 'bad') + '">' + (it.ok ? ICONS.check : ICONS.x) + ' ' +
      esc(it.check) + '：' + esc(it.msg) + '</li>';
  }).join('');
  $('wt-warn-list').innerHTML = (r.json.warnings || []).map(function (w) {
    return '<li>' + ICONS.alert + ' ' + esc(w) + '</li>';
  }).join('');
  $('wt-target-line').textContent = r.json.target ? ('預定建立：' + r.json.target) : '';
  $('wt-create').disabled = !r.json.allOk;
});
$('wt-create').addEventListener('click', async function () {
  if (oneclickRunning) { alert('一鍵同步進行中，請等它結束'); return; }
  setJobBadge('等待指令中', 'busy');   // 送出前先離開上輪終態
  const r = await apiPost('/api/worktree/create', {
    source: $('wt-source').value.trim(),
    parent: $('wt-parent').value.trim(),
    folderName: $('wt-folder').value.trim(),
    branch: $('wt-branch').value.trim(),
    startingPoint: $('wt-start').value.trim()
  });
  if (r.status === 409) {
    setJobBadge('待機', 'idle');
    // 與其他 409 分支一致：被工作擋下時展開面板讓使用者看到卡住的作業
    if (r.text === 'SUBINIT_BUSY') alert('有 Submodule 正在初始化，請等它結束後再建立 Worktree');
    else { showJobPanel(); alert('已有工作進行中，請等它結束'); }
    return;
  }
  if (!r.json || !r.json.jobId) {
    setJobBadge('待機', 'idle');
    let msg = r.text || '建立失敗';
    if (r.json && r.json.items) msg = r.json.items.join('\n');
    alert(msg);
    return;
  }
  $('wt-create').disabled = true;
  watchJob(r.json.jobId);
});

// ---------- 資料夾瀏覽器 ----------
const fm = { path: null, parent: null, targetInput: null };

function fmTargetIsDirOnly() {
  return fm.targetInput && fm.targetInput.dataset.dirsOnly === '1';
}

async function fmLoad(path) {
  const r = await apiPost('/api/browse', { path: path || '' });
  if (!r.json) { $('fm-list').innerHTML = '<div class="fm-empty">' + esc(r.text || '無法讀取') + '</div>'; return; }
  fm.path = r.json.current || null;
  fm.parent = r.json.parent;
  $('fm-current').textContent = r.json.current || '（選擇磁碟）';
  $('fm-up').disabled = !r.json.parent;
  const list = $('fm-list');
  list.innerHTML = '';
  if (!r.json.items || !r.json.items.length) {
    list.innerHTML = '<div class="fm-empty">（沒有子資料夾）</div>';
    return;
  }
  r.json.items.forEach(function (it) {
    const div = document.createElement('div');
    div.className = 'fm-item' + (it.hasGit ? ' repo-pick' : '');
    div.innerHTML = (it.hasGit ? ICONS.folderOpen : ICONS.folder) +
      '<span>' + esc(it.name) + '</span>' +
      (it.hasGit ? '<span class="git-tag">GIT</span>' : '');
    div.addEventListener('click', function () { fmLoad(it.path); });
    div.addEventListener('dblclick', function () {
      if (it.hasGit && !fmTargetIsDirOnly()) fmSelect(it.path);
    });
    list.appendChild(div);
  });
  if (r.json.truncated) {
    const d = document.createElement('div');
    d.className = 'fm-empty';
    d.textContent = '（項目過多，僅顯示前 500 個）';
    list.appendChild(d);
  }
}

function fmSelect(path) {
  if (fm.targetInput) {
    fm.targetInput.value = path;
    // 選資料夾視同確認：立即觸發驗證（若該框有驗證燈）
    if (fm.targetInput._vb) vbValidate(fm.targetInput);
  }
  invalidatePreview();   // 路徑可能已變（來源/目的），舊預覽一律作廢
  $('folder-modal').classList.add('hidden');
}

function fmOpenFor(input) {
  fm.targetInput = input;
  let start = input.value.trim();
  if (start) {
    // 從既有路徑的父資料夾開始瀏覽
    const norm = start.replace(/[\\/]+$/, '');
    const idx = Math.max(norm.lastIndexOf('\\'), norm.lastIndexOf('/'));
    if (idx > 1) start = norm.substring(0, idx);
  }
  $('folder-modal').classList.remove('hidden');
  fmLoad(start || '');
}

document.querySelectorAll('.browse-btn').forEach(function (btn) {
  if (!btn.dataset.target) return;   // 動態生成的瀏覽按鈕自带 listener
  btn.addEventListener('click', function () { fmOpenFor($(btn.dataset.target)); });
});
$('fm-close').addEventListener('click', function () { $('folder-modal').classList.add('hidden'); });
$('fm-up').addEventListener('click', function () { if (fm.parent) fmLoad(fm.parent); });
$('fm-drives').addEventListener('click', function () { fmLoad(''); });
$('fm-select').addEventListener('click', function () {
  if (!fm.path) { alert('請先進入一個資料夾'); return; }
  fmSelect(fm.path);
});
$('fm-scan').addEventListener('click', async function () {
  if (!fm.path) { alert('請先進入一個資料夾'); return; }
  $('fm-list').innerHTML = '<div class="fm-empty">掃描中（深度 2，最多 50 個）…</div>';
  const r = await apiPost('/api/browse', { path: fm.path, scan: true, depth: 2, limit: 50 });
  const list = $('fm-list');
  list.innerHTML = '';
  const repos = (r.json && r.json.repos) || [];
  if (!repos.length) { list.innerHTML = '<div class="fm-empty">此處 2 層內找不到 Git Repo</div>'; return; }
  repos.forEach(function (rp) {
    const div = document.createElement('div');
    div.className = 'fm-item repo-pick';
    div.innerHTML = ICONS.gitBranch + '<span>' + esc(rp.path) + '</span><span class="git-tag">Git Repo</span>';
    div.addEventListener('click', function () { fmSelect(rp.path); });
    list.appendChild(div);
  });
});
$('folder-modal').addEventListener('click', function (ev) {
  if (ev.target === this) $('folder-modal').classList.add('hidden');
});

// ---------- 綁定驗證燈（路徑框右內緣） ----------
// 目的 Repo 列在 addDstRow() 內掛；來源／Fetch／Worktree 框在此掛。
vbAttach($('sync-src'), 'sync-src', $('sync-src-summary'));
vbAttach($('fetch-a'), 'plain', $('fetch-a-summary'));
vbAttach($('fetch-b'), 'plain', $('fetch-b-summary'));
vbAttach($('wt-source'), 'plain', $('wt-source-summary'));

// ---------- 設定檔（多個設定 + 自動還原上次設定） ----------
let userTouchedForm = false;      // 尚未還原完成前使用者已動過欄位 -> 放棄自動還原
let pendingProfileSubs = null;    // 載入設定後待清單重畫完成再套回的 Submodule 勾選
let profileRestoring = false;     // applyProfileState 填表期間為 true（區分程式填表與使用者操作）

function profileSet(el, v) {
  if (!el) return;
  if (el.type === 'checkbox') {
    if (el.checked !== !!v) { el.checked = !!v; el.dispatchEvent(new Event('change', { bubbles: true })); }
  } else {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(el, v == null ? '' : String(v));
    el.dispatchEvent(new Event('input', { bubbles: true }));
  }
}

function collectProfileState() {
  const dsts = [];
  document.querySelectorAll('#sync-dst-rows .dst-row input').forEach(function (i) {
    const v = i.value.trim();
    if (v) dsts.push(v);
  });
  return {
    sync: { src: $('sync-src').value.trim(), dsts: dsts,
            origin: $('sync-origin').checked, heads: $('sync-heads').checked, recurse: $('sync-recurse').checked,
            forceAlways: $('sync-force-always-cb').checked,
            subs: checkedSubPaths() },
    fetch: { a: $('fetch-a').value.trim(), b: $('fetch-b').value.trim(),
             prune: $('fetch-prune').checked, recurse: $('fetch-recurse').checked },
    wt: { source: $('wt-source').value.trim(), parent: $('wt-parent').value.trim(), folder: $('wt-folder').value.trim(),
          branch: $('wt-branch').value.trim(), start: $('wt-start').value.trim() }
  };
}

function applyProfileState(st) {
  if (!st) return;
  profileRestoring = true;   // 填表觸發的 input/change 不算「使用者動過」（dispatchEvent 為同步）
  try { applyProfileStateInner(st); } finally { profileRestoring = false; }
}
function applyProfileStateInner(st) {
  const s = st.sync || {}, f = st.fetch || {}, w = st.wt || {};
  profileSet($('sync-src'), s.src);
  document.querySelectorAll('#sync-dst-rows .dst-row').forEach(function (r) { r.remove(); });
  ((s.dsts && s.dsts.length) ? s.dsts : ['']).forEach(function (p) { addDstRow(p); });
  refreshDstDels();
  profileSet($('sync-origin'), s.origin !== false);
  profileSet($('sync-heads'), !!s.heads);
  profileSet($('sync-recurse'), s.recurse !== false);
  profileSet($('sync-force-always-cb'), !!s.forceAlways);
  pendingProfileSubs = Array.isArray(s.subs) ? s.subs.slice() : null;
  profileSet($('fetch-a'), f.a);
  profileSet($('fetch-b'), f.b);
  profileSet($('fetch-prune'), !!f.prune);
  profileSet($('fetch-recurse'), f.recurse !== false);
  profileSet($('wt-source'), w.source);
  profileSet($('wt-parent'), w.parent);
  profileSet($('wt-folder'), w.folder);
  profileSet($('wt-branch'), w.branch);
  profileSet($('wt-start'), w.start);
  $('sync-preview-box').classList.add('hidden');
  $('sync-subs-details').classList.add('hidden');   // 舊清單屬舊 Repo 狀態，等重新驗證
  $('subs-toolbar').classList.add('hidden');
  invalidatePreview();
}

function profileAutoValidate() {
  ['sync-src', 'fetch-a', 'fetch-b', 'wt-source'].forEach(function (id) {
    const el = $(id);
    if (el._vb && el.value.trim()) vbValidate(el);
  });
}

// ---- 設定檔彈出面板（分頁列「設定檔」按鈕開啟）----
function profilePopOpen(show) {
  const pop = $('profile-pop');
  if (show) {
    const r = $('profile-open').getBoundingClientRect();
    const w = pop.offsetWidth || 288;   // hidden 時 offsetWidth 為 0：以 CSS 寬度估算
    pop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - w - 8)) + 'px';
    pop.style.top = (r.bottom + 6) + 'px';
  }
  pop.classList.toggle('hidden', !show);
  $('profile-open').classList.toggle('active', show);
}
let profileToastTimer = null;
function profileHint(t) {
  $('profile-hint').textContent = t || '';
  // 面板關著時（例如開頁自動還原）改用右下角 toast，避免訊息沒人看到
  if (t && $('profile-pop').classList.contains('hidden')) {
    const el = $('profile-toast');
    el.textContent = t;
    el.classList.remove('hidden');
    if (profileToastTimer) clearTimeout(profileToastTimer);
    profileToastTimer = setTimeout(function () { el.classList.add('hidden'); }, 2500);
  } else {
    // 清空訊息或面板已開（hint 寫在面板內）：順手收起還在倒數的舊 toast
    if (profileToastTimer) { clearTimeout(profileToastTimer); profileToastTimer = null; }
    $('profile-toast').classList.add('hidden');
  }
}
$('profile-open').addEventListener('click', function (ev) {
  ev.stopPropagation();
  profilePopOpen($('profile-pop').classList.contains('hidden'));
});
document.addEventListener('click', function (ev) {
  if ($('profile-pop').classList.contains('hidden')) return;
  if (ev.target.closest && (ev.target.closest('#profile-pop') || ev.target.closest('#profile-open'))) return;
  profilePopOpen(false);
});
document.addEventListener('keydown', function (ev) { if (ev.key === 'Escape') profilePopOpen(false); });
window.addEventListener('resize', function () { profilePopOpen(false); });

async function profilesRefresh(selectName) {
  let items = [];
  try {
    const res = await fetch('/api/profiles');
    const j = await res.json();
    items = (j && j.items) || [];
  } catch (e) { /* 伺服器未回應：保留佔位選項 */ }
  const sel = $('profile-select');
  const keep = (selectName != null) ? selectName : sel.value;
  sel.innerHTML = '<option value="">—— 選擇設定檔 ——</option>';
  items.forEach(function (it) {
    const o = document.createElement('option');
    o.value = it.name;
    o.textContent = it.name;
    o.title = it.mtime || '';
    sel.appendChild(o);
  });
  sel.value = keep;
  if (sel.value !== keep) sel.value = '';
  $('profile-overwrite').disabled = !sel.value;
  $('profile-delete').disabled = !sel.value;
}

async function profileSave(name) {
  const r = await apiPost('/api/profiles/save', { name: name, data: collectProfileState() });
  if (r.status === 200 && r.json && r.json.ok) {
    await profilesRefresh(name);
    profileHint('已儲存「' + name + '」' + (r.json.existed ? '（覆寫舊設定）' : ''));
  } else {
    alert('儲存失敗：' + String((r.json && r.json.error) || r.text || ('HTTP ' + r.status)).slice(0, 300));
  }
}

$('profile-select').addEventListener('change', async function () {
  const name = this.value;
  $('profile-overwrite').disabled = !name;
  $('profile-delete').disabled = !name;
  profileHint('');
  if (!name) return;
  let j = null;
  try {
    const res = await fetch('/api/profiles/get?name=' + encodeURIComponent(name));
    j = await res.json();
    if (res.status !== 200 || !j || !j.data) { profileHint('載入失敗'); return; }
  } catch (e) { profileHint('載入失敗'); return; }
  applyProfileState(j.data);
  profileHint('已載入「' + name + '」');
  profileAutoValidate();
});

$('profile-save').addEventListener('click', async function () {
  const name = (prompt('設定檔名稱：', '') || '').trim();
  if (!name) return;
  if (name.length > 60) { alert('名稱請以 60 字為限'); return; }
  if (/[\\/:*?"<>|]/.test(name) || name.indexOf('..') >= 0 || /^[_.]/.test(name)) {
    alert('名稱不可包含 \\ / : * ? " < > |，且不可用底線或句點開頭');
    return;
  }
  const exists = Array.prototype.some.call($('profile-select').options, function (o) { return o.value === name; });
  if (exists && !confirm('「' + name + '」已存在，覆寫它嗎？')) return;
  try { await profileSave(name); }
  catch (e) { alert('儲存失敗：無法連線到伺服器（' + e.message + '）'); }
});

$('profile-overwrite').addEventListener('click', function () {
  const name = $('profile-select').value;
  if (name) profileSave(name).catch(function (e) { alert('儲存失敗：無法連線到伺服器（' + e.message + '）'); });
});

$('profile-delete').addEventListener('click', async function () {
  const name = $('profile-select').value;
  if (!name) return;
  if (!confirm('刪除設定檔「' + name + '」？')) return;
  try {
    const r = await apiPost('/api/profiles/delete', { name: name });
    if (r.status === 200) { await profilesRefresh(''); profileHint('已刪除「' + name + '」'); }
    else alert('刪除失敗：' + (r.text || ('HTTP ' + r.status)));
  } catch (e) { alert('刪除失敗：無法連線到伺服器（' + e.message + '）'); }
});

// ---- 「上次設定」自動記錄／開頁自動還原 ----
let saveLastTimer = null;
function scheduleSaveLast() {
  if (profileRestoring) return;   // 還原填表不記 userTouchedForm、也不回寫
  userTouchedForm = true;
  if (saveLastTimer) clearTimeout(saveLastTimer);
  saveLastTimer = setTimeout(function () {
    saveLastTimer = null;
    apiPost('/api/profiles/last', { data: collectProfileState() }).catch(function () { });
  }, 1000);
}
const PROFILE_INPUT_IDS = ['sync-src', 'fetch-a', 'fetch-b', 'wt-source', 'wt-parent', 'wt-folder', 'wt-branch', 'wt-start'];
const PROFILE_CHECK_IDS = ['sync-origin', 'sync-heads', 'sync-recurse', 'sync-force-always-cb', 'fetch-prune', 'fetch-recurse'];
function inProfileField(t) {
  if (!t || !t.id) return false;
  if (PROFILE_INPUT_IDS.indexOf(t.id) >= 0 || PROFILE_CHECK_IDS.indexOf(t.id) >= 0) return true;
  return !!(t.closest && (t.closest('#sync-dst-rows') || t.closest('#sync-subs-list')));
}
document.addEventListener('input', function (ev) { if (inProfileField(ev.target)) scheduleSaveLast(); });
document.addEventListener('change', function (ev) { if (inProfileField(ev.target)) scheduleSaveLast(); });

(async function initProfileRestore() {
  await profilesRefresh('');
  try {
    const res = await fetch('/api/profiles/last');
    const j = await res.json();
    if (j && j.data && !userTouchedForm) {
      applyProfileState(j.data);
      profileHint('已還原上次設定');
      profileAutoValidate();
    }
  } catch (e) { /* 伺服器未回應：維持空表單 */ }
})();
