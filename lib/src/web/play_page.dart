import 'dart:convert';

/// Renders the two screens of the web UI.
///
/// Both are single self-contained documents with no build step and no CDN: the
/// proxy is a local developer tool, and a page that broke without internet
/// access would be a worse product than one with hand-written CSS.
class WebPages {
  const WebPages();

  /// Media library, served at `/`.
  String library() => _document(
    title: 'proxy_video - media library',
    body: _libraryBody,
    script: '$_sharedScript\n$_libraryScript',
  );

  /// Player plus cache diagnostics, served at `/play/<key>`.
  String player(String key) => _document(
    title: 'proxy_video - ${_escape(key)}',
    body: _playerBody,
    script:
        'window.PROXY_VIDEO = ${jsonEncode(<String, Object?>{'key': key})};\n'
        '$_sharedScript\n$_playerScript',
  );

  static String _document({
    required String title,
    required String body,
    required String script,
  }) =>
      '<!DOCTYPE html>\n'
      '<html lang="en">\n'
      '<head>\n'
      '<meta charset="utf-8">\n'
      '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
      '<title>$title</title>\n'
      '<style>$_styles</style>\n'
      '</head>\n'
      '<body>\n'
      '$body\n'
      '<script>\n$script\n</script>\n'
      '</body>\n'
      '</html>\n';

  static String _escape(String value) => const HtmlEscape().convert(value);
}

const String _styles = r'''
:root{
  --bg:#0B0F1A; --bg-2:#111827; --bg-3:#1F2937;
  --fg:#F9FAFB; --muted:#9CA3AF; --dim:#6B7280;
  --indigo:#6366F1; --violet:#8B5CF6; --cyan:#22D3EE;
  --ok:#10B981; --bad:#EF4444; --warn:#F59E0B; --info:#38BDF8;
  --glass:rgba(255,255,255,.045);
  --glass-strong:rgba(255,255,255,.075);
  --line:rgba(255,255,255,.10);
  --radius:16px;
  --shadow:0 18px 40px -22px rgba(0,0,0,.85);
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{
  min-height:100vh; background:var(--bg); color:var(--fg);
  font:400 14px/1.55 'Noto Sans','Segoe UI',system-ui,Roboto,Helvetica,Arial,sans-serif;
  -webkit-font-smoothing:antialiased; display:flex; flex-direction:column;
  overflow-x:hidden;
}
body::before,body::after{
  content:''; position:fixed; border-radius:50%; filter:blur(130px);
  opacity:.30; pointer-events:none; z-index:0;
}
body::before{width:620px;height:620px;background:var(--indigo);top:-260px;left:-180px}
body::after{width:560px;height:560px;background:var(--cyan);bottom:-280px;right:-160px}
a{color:var(--cyan);text-decoration:none}
a:hover{text-decoration:underline}
code,kbd{font-family:'JetBrains Mono',Consolas,monospace;font-size:.86em}
h1,h2,h3{margin:0;font-weight:700;letter-spacing:-.01em}
h1{font-size:28px}
h2{font-size:16px;font-weight:600}
.wrap{position:relative;z-index:1;width:100%;max-width:1440px;margin:0 auto;padding:0 28px}
.stack{display:flex;flex-direction:column;gap:22px;padding:26px 0 40px}
.row{display:flex;align-items:center;gap:14px}
.row.between{justify-content:space-between}
.row.wrap-row{flex-wrap:wrap}
.spread{flex:1 1 auto}
.muted{color:var(--muted)}
.dim{color:var(--dim)}
.tiny{font-size:12px}
.mono{font-family:'JetBrains Mono',Consolas,monospace}

/* ---------------------------------------------------------------- topbar */
.topbar{
  position:sticky; top:0; z-index:20;
  background:rgba(11,15,26,.72); backdrop-filter:blur(18px);
  border-bottom:1px solid var(--line);
}
.topbar .wrap{display:flex;align-items:center;gap:16px;height:64px}
.brand{display:flex;align-items:center;gap:11px;font-weight:700;font-size:17px}
.brand .dot{
  width:11px;height:11px;border-radius:50%;
  background:linear-gradient(135deg,var(--cyan),var(--violet));
  box-shadow:0 0 16px rgba(34,211,238,.75);
  animation:breathe 2.6s ease-in-out infinite;
}
.brand .name{
  background:linear-gradient(92deg,var(--cyan),var(--violet) 55%,var(--indigo));
  -webkit-background-clip:text; background-clip:text; color:transparent;
}
.crumbs{display:flex;align-items:center;gap:9px;min-width:0}
.crumbs .key{
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  max-width:46vw;color:var(--fg);font-weight:600;
}

/* ---------------------------------------------------------------- buttons */
.btn{
  appearance:none; border:1px solid var(--line); background:var(--glass);
  color:var(--fg); font:inherit; font-weight:600; font-size:13px;
  padding:9px 15px; border-radius:11px; cursor:pointer;
  transition:transform .16s ease,background .16s ease,border-color .16s ease,box-shadow .16s ease;
  white-space:nowrap;
}
.btn:hover{background:var(--glass-strong);transform:translateY(-1px)}
.btn:active{transform:translateY(0)}
.btn:disabled{opacity:.45;cursor:not-allowed;transform:none}
.btn-primary{
  border-color:transparent;
  background:linear-gradient(120deg,var(--indigo),var(--violet) 55%,var(--cyan));
  box-shadow:0 12px 26px -14px rgba(99,102,241,.95);
}
.btn-primary:hover{box-shadow:0 16px 30px -12px rgba(139,92,246,.95)}
.btn-danger{border-color:rgba(239,68,68,.45);color:#FCA5A5}
.btn-danger:hover{background:rgba(239,68,68,.13)}
.btn-sm{padding:6px 11px;font-size:12px;border-radius:9px}

/* ---------------------------------------------------------------- surfaces */
.card{
  background:var(--glass); border:1px solid var(--line); border-radius:var(--radius);
  backdrop-filter:blur(16px); box-shadow:var(--shadow);
}
.pad{padding:20px}
.field{display:flex;flex-direction:column;gap:6px}
.field label{font-size:12px;font-weight:600;color:var(--muted);letter-spacing:.02em}
.input{
  width:100%; padding:10px 12px; border-radius:11px; font:inherit;
  background:rgba(6,9,17,.7); border:1px solid var(--line); color:var(--fg);
  transition:border-color .16s ease,box-shadow .16s ease;
}
.input:focus{outline:none;border-color:rgba(34,211,238,.6);box-shadow:0 0 0 3px rgba(34,211,238,.13)}
.input::placeholder{color:var(--dim)}

/* ---------------------------------------------------------------- pills */
.pill{
  display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:999px;
  font-size:11.5px;font-weight:600;letter-spacing:.02em;
  border:1px solid var(--line); background:var(--glass); color:var(--muted);
}
.pill .dot{width:7px;height:7px;border-radius:50%;background:var(--dim)}
.pill.ok{color:#6EE7B7;border-color:rgba(16,185,129,.4)}
.pill.ok .dot{background:var(--ok);box-shadow:0 0 10px rgba(16,185,129,.8)}
.pill.busy{color:#FCD34D;border-color:rgba(245,158,11,.4)}
.pill.busy .dot{background:var(--warn);animation:pulse 1.15s ease-in-out infinite}
.pill.err{color:#FCA5A5;border-color:rgba(239,68,68,.4)}
.pill.err .dot{background:var(--bad)}

/* ---------------------------------------------------------------- media grid */
.grid{
  display:grid; gap:18px;
  grid-template-columns:repeat(auto-fill,minmax(288px,1fr));
}
.thumb{
  position:relative; aspect-ratio:16/9; border-radius:13px; overflow:hidden;
  background:
    radial-gradient(120% 120% at 12% 8%,rgba(99,102,241,.55),transparent 55%),
    radial-gradient(110% 110% at 88% 92%,rgba(34,211,238,.42),transparent 55%),
    linear-gradient(160deg,#161C2E,#0D1220);
  display:flex;align-items:center;justify-content:center;
}
.thumb .glyph{
  width:52px;height:52px;border-radius:50%;
  border:1px solid rgba(255,255,255,.28); background:rgba(255,255,255,.10);
  display:flex;align-items:center;justify-content:center;
  backdrop-filter:blur(8px); transition:transform .2s ease,background .2s ease;
}
.thumb .glyph::after{
  content:'';width:0;height:0;margin-left:4px;
  border-left:14px solid #fff;border-top:9px solid transparent;border-bottom:9px solid transparent;
}
.media-card{
  transition:transform .18s ease,box-shadow .18s ease,border-color .18s ease;
  display:flex;flex-direction:column;overflow:hidden;
}
.media-card:hover{transform:translateY(-4px);border-color:rgba(139,92,246,.5);box-shadow:0 26px 48px -26px rgba(0,0,0,.95)}
.media-card:hover .glyph{transform:scale(1.08);background:rgba(255,255,255,.2)}
.media-card .body{padding:15px 16px 16px;display:flex;flex-direction:column;gap:11px}
.media-card .title{
  font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
}
.bar{position:relative;height:7px;border-radius:999px;background:rgba(255,255,255,.08);overflow:hidden}
.bar>span{
  display:block;height:100%;border-radius:999px;
  background:linear-gradient(90deg,var(--cyan),var(--violet));
  transition:width .45s cubic-bezier(.22,1,.36,1);
}
.bar>.shine{
  position:absolute;inset:0;width:34%;
  background:linear-gradient(90deg,transparent,rgba(255,255,255,.30),transparent);
  animation:shimmer 1.9s linear infinite;
}

/* ---------------------------------------------------------------- chunk bits */
.bits{
  display:grid; gap:3px;
  grid-template-columns:repeat(auto-fill,minmax(11px,1fr));
}
.bits i{
  display:block; aspect-ratio:1/1; border-radius:3px;
  background:rgba(255,255,255,.07); transition:background .3s ease,box-shadow .3s ease;
}
.bits i.on{background:linear-gradient(140deg,var(--cyan),var(--ok));box-shadow:0 0 8px rgba(34,211,238,.45)}
.bits i.hot{background:linear-gradient(140deg,var(--violet),var(--indigo));animation:pulse 1.1s ease-in-out infinite}

/* ---------------------------------------------------------------- player */
.player-shell{display:grid;gap:22px;grid-template-columns:minmax(0,1fr)}
@media (min-width:1200px){
  .player-shell{grid-template-columns:minmax(0,1.62fr) minmax(330px,1fr)}
}
.stage{
  position:relative;border-radius:var(--radius);overflow:hidden;
  background:linear-gradient(160deg,#0A0E18,#05070D);
  border:1px solid var(--line); box-shadow:var(--shadow);
  display:flex;align-items:center;justify-content:center;min-height:260px;
}
.stage video{width:100%;max-height:70vh;display:block;background:#000}
.stage::after{
  content:'';position:absolute;inset:0;pointer-events:none;border-radius:var(--radius);
  box-shadow:inset 0 0 0 1px rgba(255,255,255,.05), inset 0 -90px 90px -70px rgba(34,211,238,.35);
}
.kv{display:grid;grid-template-columns:auto 1fr;gap:8px 16px;align-items:baseline}
.kv dt{color:var(--muted);font-size:12px}
.kv dd{margin:0;font-weight:600;font-family:'JetBrains Mono',Consolas,monospace;font-size:13px}
.section{display:flex;flex-direction:column;gap:12px}
.section+.section{padding-top:18px;border-top:1px solid var(--line)}

/* ---------------------------------------------------------------- misc */
.empty{
  padding:56px 24px;text-align:center;color:var(--muted);
  border:1px dashed var(--line);border-radius:var(--radius);
}
.toast{
  position:fixed;left:50%;bottom:26px;transform:translateX(-50%) translateY(24px);
  background:rgba(17,24,39,.96);border:1px solid var(--line);border-radius:12px;
  padding:11px 18px;font-size:13px;font-weight:600;opacity:0;pointer-events:none;
  transition:opacity .2s ease,transform .2s ease;z-index:40;max-width:80vw;
}
.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
.toast.err{border-color:rgba(239,68,68,.55);color:#FCA5A5}
.footbar{
  margin-top:auto;border-top:1px solid var(--line);
  background:rgba(11,15,26,.7);backdrop-filter:blur(14px);
}
.footbar .wrap{display:flex;align-items:center;gap:18px;flex-wrap:wrap;padding-top:13px;padding-bottom:13px}

@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.55;transform:scale(.9)}}
@keyframes breathe{0%,100%{opacity:.75;transform:scale(.9)}50%{opacity:1;transform:scale(1.12)}}
@keyframes shimmer{0%{transform:translateX(-110%)}100%{transform:translateX(310%)}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
''';

const String _sharedScript = r'''
function el(tag, cls, text) {
  var node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

function formatBytes(bytes) {
  if (bytes === null || bytes === undefined) return '-';
  if (bytes < 1024) return bytes + ' B';
  var units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes / 1024;
  var index = 0;
  while (value >= 1024 && index < units.length - 1) { value /= 1024; index++; }
  return (value >= 100 ? value.toFixed(0) : value.toFixed(2)) + ' ' + units[index];
}

function formatClock(seconds) {
  if (!isFinite(seconds)) return '0:00';
  seconds = Math.max(0, Math.floor(seconds));
  var m = Math.floor(seconds / 60);
  var s = seconds % 60;
  return m + ':' + (s < 10 ? '0' : '') + s;
}

function encodeKey(key) {
  return key.split('/').map(encodeURIComponent).join('/');
}

function decodeBase64(text) {
  try { return atob(text || ''); } catch (error) { return ''; }
}

function toast(message, isError) {
  var node = document.getElementById('toast');
  if (!node) return;
  node.textContent = message;
  node.className = 'toast show' + (isError ? ' err' : '');
  clearTimeout(node._timer);
  node._timer = setTimeout(function () { node.className = 'toast'; }, 3600);
}

async function api(path, options) {
  var response = await fetch(path, options);
  var text = await response.text();
  var payload = null;
  try { payload = text ? JSON.parse(text) : null; } catch (error) { payload = { error: text }; }
  if (!response.ok) {
    var detail = payload && payload.error ? payload.error : ('HTTP ' + response.status);
    throw new Error(detail);
  }
  return payload;
}

function pill(label, cls) {
  var node = el('span', 'pill ' + (cls || ''));
  node.appendChild(el('span', 'dot'));
  node.appendChild(el('span', null, label));
  return node;
}
''';

const String _libraryBody = r'''
<header class="topbar">
  <div class="wrap">
    <div class="brand"><span class="dot"></span><span class="name">proxy_video</span></div>
    <span class="pill" id="origin-pill">origin</span>
    <span class="spread"></span>
    <button class="btn" id="refresh">Refresh</button>
    <button class="btn btn-primary" id="toggle-panel">Transcode &amp; upload</button>
  </div>
</header>

<div class="wrap stack">
  <section class="card pad" id="panel" hidden>
    <div class="row between" style="margin-bottom:16px">
      <h2>Transcode &amp; upload</h2>
      <span class="tiny muted">ffmpeg runs on this machine, then the result is published for the proxy.</span>
    </div>
    <form id="job-form" class="row wrap-row" style="gap:14px;align-items:flex-end">
      <div class="field" style="flex:2 1 320px">
        <label for="input">Source file (absolute path on this machine)</label>
        <input class="input mono" id="input" placeholder="C:\videos\movie.mov" autocomplete="off">
      </div>
      <div class="field" style="flex:1 1 200px">
        <label for="key">Destination key</label>
        <input class="input mono" id="key" placeholder="clips/movie.mp4" autocomplete="off">
      </div>
      <div class="field" style="flex:0 0 118px">
        <label for="preset">Preset</label>
        <select class="input" id="preset">
          <option value="ultrafast">ultrafast</option>
          <option value="superfast">superfast</option>
          <option value="veryfast" selected>veryfast</option>
          <option value="fast">fast</option>
          <option value="medium">medium</option>
          <option value="slow">slow</option>
        </select>
      </div>
      <button class="btn btn-primary" type="submit" id="submit-job">Start</button>
      <button class="btn" type="button" id="demo-job">Synthesize a demo clip</button>
    </form>
    <div id="job-state" style="margin-top:18px" hidden>
      <div class="row between" style="margin-bottom:9px">
        <span class="mono tiny" id="job-label">queued</span>
        <span class="mono tiny muted" id="job-percent"></span>
      </div>
      <div class="bar"><span id="job-bar" style="width:0%"></span><span class="shine"></span></div>
    </div>
  </section>

  <div class="row between">
    <h1>Media library</h1>
    <span class="tiny muted" id="count"></span>
  </div>

  <div class="grid" id="media"></div>
  <div class="empty" id="empty" hidden>
    Nothing published yet. Use <b>Transcode &amp; upload</b> above, or run
    <code class="mono">dart run bin/pipeline.dart --demo</code>.
  </div>
</div>

<footer class="footbar">
  <div class="wrap">
    <span class="pill" id="status-cache">cache</span>
    <span class="pill" id="status-upstream">upstream</span>
    <span class="pill" id="status-app">app</span>
    <span class="spread"></span>
    <span class="tiny dim" id="status-origin"></span>
  </div>
</footer>
<div class="toast" id="toast"></div>
''';

const String _libraryScript = r'''
var mediaCache = [];

function cachePill(entry) {
  if (!entry || !entry.chunkCount) return pill('not cached', '');
  if (entry.complete) return pill('fully cached', 'ok');
  return pill(entry.readyChunks + '/' + entry.chunkCount + ' chunks', 'busy');
}

function renderMedia(objects) {
  var host = document.getElementById('media');
  host.textContent = '';
  document.getElementById('empty').hidden = objects.length > 0;
  document.getElementById('count').textContent =
    objects.length + (objects.length === 1 ? ' object' : ' objects');

  objects.forEach(function (object) {
    var card = el('article', 'card media-card');
    var thumb = el('div', 'thumb');
    thumb.appendChild(el('div', 'glyph'));

    var body = el('div', 'body');
    var title = el('div', 'title', object.key);
    title.title = object.key;
    body.appendChild(title);

    var meta = el('div', 'row tiny muted');
    meta.appendChild(el('span', null, formatBytes(object.size)));
    meta.appendChild(el('span', null, '\u00b7'));
    meta.appendChild(el('span', 'mono', (object.contentType || 'unknown').split(';')[0]));
    body.appendChild(meta);

    var cache = object.cache || null;
    var fraction = cache ? Math.max(0, Math.min(1, cache.cachedFraction || 0)) : 0;
    var bar = el('div', 'bar');
    var fill = el('span');
    fill.style.width = (fraction * 100).toFixed(1) + '%';
    bar.appendChild(fill);
    if (object.cache && !object.cache.complete) bar.appendChild(el('span', 'shine'));
    body.appendChild(bar);

    var footer = el('div', 'row between');
    footer.setAttribute('data-key', object.key);
    footer.appendChild(cachePill(cache));
    var play = el('a', 'btn btn-sm btn-primary', 'Play');
    play.href = object.playUrl;
    footer.appendChild(play);
    body.appendChild(footer);

    card.appendChild(thumb);
    card.appendChild(body);
    host.appendChild(card);
  });
}

async function loadMedia() {
  var payload = await api('/api/media');
  mediaCache = payload.objects || [];
  renderMedia(mediaCache);
}

async function loadStats() {
  var stats = await api('/api/stats');

  document.getElementById('status-cache').replaceWith(
    withId(pill(formatBytes(stats.totalBytes) + ' cached', 'ok'), 'status-cache'));
  document.getElementById('status-upstream').replaceWith(
    withId(pill('upstream ' + stats.upstreamInUse + '/' + stats.upstreamCapacity, ''),
      'status-upstream'));
  document.getElementById('status-app').replaceWith(
    withId(pill('chunk ' + formatBytes(stats.chunkSize), ''), 'status-app'));

  var byKey = {};
  (stats.entries || []).forEach(function (entry) { byKey[entry.key] = entry; });

  Array.prototype.forEach.call(document.querySelectorAll('[data-key]'), function (row) {
    var entry = byKey[row.getAttribute('data-key')];
    var existing = row.querySelector('.pill');
    var next = cachePill(entry);
    if (existing) row.replaceChild(next, existing); else row.insertBefore(next, row.firstChild);
  });
}

function withId(node, id) { node.id = id; return node; }

async function pollJob(id) {
  var state = document.getElementById('job-state');
  state.hidden = false;

  for (;;) {
    var job = await api('/api/jobs/' + encodeURIComponent(id));
    var percent = job.progress === null || job.progress === undefined
      ? null : Math.round(job.progress * 100);
    document.getElementById('job-label').textContent =
      job.status + ' \u00b7 ' + job.phase;
    document.getElementById('job-percent').textContent = percent === null ? '' : percent + '%';
    document.getElementById('job-bar').style.width =
      (job.finished && job.status === 'done' ? 100 : (percent || 0)) + '%';

    if (job.status === 'done') {
      toast('Published ' + job.key + ' (' + formatBytes(job.outputBytes) + ')');
      await loadMedia();
      await loadStats();
      return;
    }
    if (job.status === 'failed') {
      throw new Error(job.message || 'transcode failed');
    }
    await new Promise(function (resolve) { setTimeout(resolve, 700); });
  }
}

async function submitJob(demo) {
  var input = document.getElementById('input').value.trim();
  var key = document.getElementById('key').value.trim();
  var payload = { demo: demo, preset: document.getElementById('preset').value };
  if (!demo) { payload.input = input; }
  if (key) { payload.key = key; }
  if (demo) { payload.duration = 12; }

  document.getElementById('submit-job').disabled = true;
  document.getElementById('demo-job').disabled = true;
  try {
    var job = await api('/api/transcode', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    await pollJob(job.id);
  } catch (error) {
    toast(error.message, true);
    document.getElementById('job-state').hidden = true;
  } finally {
    document.getElementById('submit-job').disabled = false;
    document.getElementById('demo-job').disabled = false;
  }
}

document.getElementById('toggle-panel').addEventListener('click', function () {
  var panel = document.getElementById('panel');
  panel.hidden = !panel.hidden;
});
document.getElementById('refresh').addEventListener('click', async function () {
  try { await loadMedia(); await loadStats(); toast('Reloaded'); }
  catch (error) { toast(error.message, true); }
});
document.getElementById('job-form').addEventListener('submit', function (event) {
  event.preventDefault();
  submitJob(false);
});
document.getElementById('demo-job').addEventListener('click', function () { submitJob(true); });

(async function () {
  try {
    var health = await api('/healthz');
    document.getElementById('status-origin').textContent = 'origin ' + health.origin;
    document.getElementById('origin-pill').replaceWith(
      withId(pill(health.storage.replace('LocalDirStorage', 'local dir').replace('CosStorage', 'COS'),
        'ok'), 'origin-pill'));
    await loadMedia();
    await loadStats();
    setInterval(function () { loadStats().catch(function () {}); }, 1500);
  } catch (error) {
    toast(error.message, true);
  }
})();
''';

const String _playerBody = r'''
<header class="topbar">
  <div class="wrap">
    <a class="btn btn-sm" href="/">&#8592; Library</a>
    <div class="crumbs">
      <span class="pill" id="cache-pill">cache</span>
      <span class="key mono" id="title"></span>
    </div>
    <span class="spread"></span>
    <button class="btn" id="reload">Reload</button>
    <button class="btn btn-danger" id="reset">Clear this cache</button>
  </div>
</header>

<div class="wrap stack">
  <div class="player-shell">
    <section class="stage">
      <video id="video" controls preload="metadata" playsinline></video>
    </section>

    <aside class="card pad section" style="align-self:start">
      <div>
        <h2>Cache diagnostics</h2>
        <p class="tiny muted" style="margin:6px 0 0">
          Each square is one cache chunk. Green means the bytes are already on disk;
          purple marks chunks being fetched right now.
        </p>
      </div>

      <div class="bits" id="bits"></div>

      <div class="section">
        <div class="row between tiny">
          <span class="muted">cached</span>
          <span class="mono" id="cached-label">-</span>
        </div>
        <div class="bar"><span id="cached-bar" style="width:0%"></span><span class="shine"></span></div>
      </div>

      <dl class="kv section">
        <dt>position</dt><dd id="stat-position">0:00</dd>
        <dt>buffered</dt><dd id="stat-buffered">-</dd>
        <dt>chunks</dt><dd id="stat-chunks">-</dd>
        <dt>upstream reqs</dt><dd id="stat-upstream">-</dd>
        <dt>hit rate</dt><dd id="stat-hitrate">-</dd>
        <dt>size</dt><dd id="stat-size">-</dd>
      </dl>

      <div class="section">
        <span class="tiny muted">Jump to (proves seeking does not re-download)</span>
        <div class="row wrap-row">
          <button class="btn btn-sm" data-seek="0.25">25%</button>
          <button class="btn btn-sm" data-seek="0.5">50%</button>
          <button class="btn btn-sm" data-seek="0.75">75%</button>
          <button class="btn btn-sm" data-seek="0.99">End</button>
        </div>
      </div>
    </aside>
  </div>
</div>

<footer class="footbar">
  <div class="wrap">
    <span class="pill" id="status-upstream">upstream</span>
    <span class="pill" id="status-fills">background fills</span>
    <span class="spread"></span>
    <span class="tiny dim" id="stream-url"></span>
  </div>
</footer>
<div class="toast" id="toast"></div>
''';

const String _playerScript = r'''
var key = window.PROXY_VIDEO.key;
var video = document.getElementById('video');
var bitCells = [];
var lastChunkCount = -1;
var lastReady = -1;

document.getElementById('title').textContent = key;
document.getElementById('stream-url').textContent = '/media/' + encodePath(key);
video.src = '/media/' + encodePath(key);

function encodePath(value) {
  return value.split('/').map(encodeURIComponent).join('/');
}

function renderBits(entry) {
  var host = document.getElementById('bits');
  var count = entry && entry.chunkCount ? entry.chunkCount : 0;
  var ready = entry && entry.readyChunks ? entry.readyChunks : 0;

  // A 4 GiB file is 4096 chunks; one DOM node each would be wasteful, so cells
  // are grouped once the count gets large and show the average fill instead.
  var cells = Math.min(count || 1, 320);
  var group = count > 0 ? count / cells : 1;

  if (cells !== bitCells.length) {
    host.textContent = '';
    bitCells = [];
    for (var i = 0; i < cells; i++) {
      var cell = el('i');
      bitCells.push(cell);
      host.appendChild(cell);
    }
    lastChunkCount = -1;
    lastReady = -1;
  }

  if (count === lastChunkCount && ready === lastReady) return;
  lastChunkCount = count;
  lastReady = ready;

  if (!count) {
    bitCells.forEach(function (cell) { cell.className = ''; });
    return;
  }

  var binary = decodeBase64(entry.chunkBitmap);
  for (var cell = 0; cell < cells; cell++) {
    var filled = 0;
    var total = 0;
    var from = Math.floor(cell * group);
    var to = Math.min(count, Math.max(from + 1, Math.floor((cell + 1) * group)));
    for (var index = from; index < to; index++) {
      total++;
      if (binary.charCodeAt(index >> 3) & (1 << (index & 7))) filled++;
    }
    var ratio = total ? filled / total : 0;
    var node = bitCells[cell];
    if (ratio >= 1) node.className = 'on';
    else if (ratio > 0) node.className = 'hot';
    else node.className = '';
  }
}

function bufferedText() {
  if (!video.buffered || !video.buffered.length) return '-';
  var parts = [];
  for (var i = 0; i < video.buffered.length && i < 3; i++) {
    parts.push(formatClock(video.buffered.start(i)) + ' - ' + formatClock(video.buffered.end(i)));
  }
  return parts.join(', ');
}

async function loadDiagnostics() {
  var entry = await api('/api/stats?key=' + encodeURIComponent(key));

  if (!entry.known) {
    document.getElementById('cached-label').textContent = 'nothing fetched yet';
    renderBits(null);
    return;
  }

  renderBits(entry);
  document.getElementById('cached-label').textContent =
    formatBytes(entry.cachedBytes) + ' / ' + formatBytes(entry.totalSize);
  document.getElementById('cached-bar').style.width =
    ((entry.cachedFraction || 0) * 100).toFixed(1) + '%';
  document.getElementById('stat-chunks').textContent =
    entry.readyChunks + ' / ' + entry.chunkCount + ' (' + formatBytes(entry.chunkSize) + ' each)';
  document.getElementById('stat-upstream').textContent = entry.upstreamRequests;
  document.getElementById('stat-hitrate').textContent = entry.cacheHitRate === null ||
    entry.cacheHitRate === undefined
    ? 'n/a' : Math.round(entry.cacheHitRate * 100) + '%';
  document.getElementById('stat-size').textContent = formatBytes(entry.totalSize);

  var pillNode = entry.complete
    ? pill('fully cached', 'ok')
    : pill(entry.readyChunks + '/' + entry.chunkCount + ' chunks', 'busy');
  pillNode.id = 'cache-pill';
  document.getElementById('cache-pill').replaceWith(pillNode);

  document.getElementById('status-upstream').replaceWith(withId(
    pill('upstream ' + entry.upstreamInUse + '/' + entry.upstreamCapacity, ''),
    'status-upstream'));
}

video.addEventListener('timeupdate', function () {
  document.getElementById('stat-position').textContent =
    formatClock(video.currentTime) + ' / ' + formatClock(video.duration);
});
video.addEventListener('progress', function () {
  document.getElementById('stat-buffered').textContent = bufferedText();
});
video.addEventListener('loadedmetadata', function () {
  document.getElementById('stat-buffered').textContent = bufferedText();
});

Array.prototype.forEach.call(document.querySelectorAll('[data-seek]'), function (button) {
  button.addEventListener('click', function () {
    if (!isFinite(video.duration) || video.duration <= 0) {
      toast('Duration is not known yet', true);
      return;
    }
    video.currentTime = Math.min(video.duration * 0.995, video.duration * parseFloat(button.getAttribute('data-seek')));
    video.play().catch(function () {});
  });
});

document.getElementById('reload').addEventListener('click', function () {
  video.load();
  toast('Reloaded the stream');
});

document.getElementById('reset').addEventListener('click', async function () {
  try {
    await api('/api/cache', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key: key })
    });
    video.load();
    toast('Cache cleared for this video');
    await loadDiagnostics();
  } catch (error) {
    toast(error.message, true);
  }
});

(async function () {
  try {
    await loadDiagnostics();
    setInterval(function () { loadDiagnostics().catch(function () {}); }, 900);
  } catch (error) {
    toast(error.message, true);
  }
})();
''';
