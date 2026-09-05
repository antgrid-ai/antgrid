/**
 * The capture viewer, as one self-contained document.
 *
 * Inlined rather than served from a file because the bridge ships as a single
 * `bun build --compile` binary: a page read from disk at request time is a path
 * that exists on a developer's checkout and nowhere on a user's machine.
 *
 * `String.raw` so the page's own escapes survive verbatim — the SSE parser needs
 * the two characters of \n\n and the sanitiser the six of \u0000, and a plain
 * template literal would eat both. The one consequence is that a backtick or a
 * dollar-brace anywhere below would terminate or interpolate this string, so the
 * page uses neither.
 *
 * Every field rendered here was written by a peer — a message type from the
 * relay, a body from an agent's stdout, a detail map an older app stamped — so
 * NOTHING in this page may reach the DOM as markup. Values go in through
 * textContent only; `clean()` additionally drops control characters and bidi
 * overrides, which cannot execute but can silently reorder a line so it reads as
 * a different frame than the one recorded.
 */
const PAGE = String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>antgrid netwatch</title>
<style nonce="__NONCE__">
:root{
  --bg:#0b0d10; --panel:#12151a; --panel2:#171b22; --line:#242b35;
  --fg:#d6dbe3; --dim:#7c8796; --dimmer:#5a6472;
  --tx:#5cc8f5; --rx:#7ee787; --drop:#ff7b72; --warn:#f0b849; --accent:#6ea8fe; --app:#c07bf0;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
  --sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
}
*{box-sizing:border-box}
[hidden]{display:none!important}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:12px/1.45 var(--sans);overflow:hidden}
button,input{font:inherit;color:inherit}

#page{display:flex;flex-direction:column;height:100%}
#bar{display:flex;align-items:center;gap:8px;padding:6px 10px;background:var(--panel);
     border-bottom:1px solid var(--line);flex-wrap:wrap;flex:none}
#dot{width:8px;height:8px;border-radius:50%;background:var(--dimmer);flex:none}
#dot.live{background:var(--rx);box-shadow:0 0 6px var(--rx)}
#dot.retry{background:var(--warn)}
#dot.dead{background:var(--drop)}
#title{font-weight:600;letter-spacing:.02em}
#title small{color:var(--dim);font-weight:400}

.seg{display:flex;border:1px solid var(--line);border-radius:5px;overflow:hidden}
.seg button{background:none;border:0;padding:3px 9px;color:var(--dim);cursor:pointer}
.seg button+button{border-left:1px solid var(--line)}
.seg button.on{background:var(--panel2);color:var(--fg)}
.tog{background:none;border:1px solid var(--line);border-radius:5px;padding:3px 9px;
     color:var(--dim);cursor:pointer}
.tog:hover,.seg button:hover{color:var(--fg)}
.tog.on{background:var(--panel2);color:var(--fg);border-color:var(--accent)}
.tog.warn.on{border-color:var(--warn);color:var(--warn)}
.tog.busy{opacity:.5;pointer-events:none}
#q{flex:1;min-width:140px;background:var(--bg);border:1px solid var(--line);border-radius:5px;
   padding:3px 8px;font-family:var(--mono)}
#q:focus{outline:none;border-color:var(--accent)}
#counts{color:var(--dim);font-family:var(--mono);white-space:nowrap;margin-left:auto}

#note{padding:4px 10px;background:#2a2110;color:var(--warn);border-bottom:1px solid var(--line);
      font-family:var(--mono);flex:none}
#err{padding:4px 10px;background:#2a1414;color:var(--drop);border-bottom:1px solid var(--line);
     font-family:var(--mono);flex:none}

#wrap{display:flex;flex:1;min-height:0;position:relative}
#main{display:flex;flex-direction:column;flex:1;min-width:0}

.cols{display:grid;grid-template-columns:96px 22px 52px 42px 60px 58px 100px minmax(0,1fr);
      gap:10px;padding:0 10px;font-family:var(--mono);white-space:nowrap}
#head{background:var(--panel);border-bottom:1px solid var(--line);color:var(--dimmer);
      padding-top:3px;padding-bottom:3px;text-transform:uppercase;font-size:10px;
      letter-spacing:.05em;flex:none}
#scroll{flex:1;overflow-y:auto;overflow-x:hidden;min-height:0}
#rows{padding-bottom:8px}

.r{border-left:2px solid transparent;cursor:default}
.r:hover{background:#161a21}
.r.sel{background:#1b2230}
.r.fromapp{border-left-color:var(--app)}
.r .cols>div{overflow:hidden;text-overflow:ellipsis}
.dim{color:var(--dim)}
.d.tx{color:var(--tx)}
.d.rx{color:var(--rx)}
.d.x{color:var(--drop)}
.r.drop .ty{color:var(--drop)}
.by{text-align:right;color:var(--dim)}
.fr{color:var(--dimmer)}
.tr{color:var(--dim)}
.tr.local{color:var(--fg)}
.det{color:var(--dim)}
.bodyline{font-family:var(--mono);color:var(--dim);padding:0 10px 2px 118px;
          white-space:pre;overflow:hidden;text-overflow:ellipsis}
.mark{padding:2px 10px;color:var(--accent);font-family:var(--mono);background:#101720;
      border-top:1px solid var(--line);border-bottom:1px solid var(--line)}

#jump{position:absolute;left:50%;transform:translateX(-50%);bottom:16px;background:var(--accent);
      color:#08111f;border:0;border-radius:14px;padding:5px 14px;cursor:pointer;font-weight:600;
      box-shadow:0 4px 14px rgba(0,0,0,.5)}

#detail{width:400px;flex:none;border-left:1px solid var(--line);background:var(--panel);
        overflow-y:auto;padding:10px}
#detail h2{margin:0 0 8px;font-size:12px;color:var(--dim);font-weight:600;display:flex;
           align-items:center;gap:6px}
#detail h2 button{background:none;border:1px solid var(--line);border-radius:4px;
                  padding:2px 7px;color:var(--dim);cursor:pointer;font-weight:400}
#detail h2 .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;
               font-family:var(--mono);color:var(--fg)}
.kv{display:grid;grid-template-columns:84px minmax(0,1fr);gap:2px 10px;font-family:var(--mono)}
.kv dt{color:var(--dimmer)}
.kv dd{margin:0;overflow-wrap:anywhere}
#body{margin:10px 0 0;padding:8px;background:var(--bg);border:1px solid var(--line);
      border-radius:5px;font-family:var(--mono);white-space:pre-wrap;overflow-wrap:anywhere;
      max-height:44vh;overflow:auto}
#bodyh{margin:10px 0 0;color:var(--dimmer);font-family:var(--mono)}

#gate{padding:28px;max-width:640px;font-family:var(--mono);color:var(--dim);line-height:1.8}
#gate .b{color:var(--fg)}
#gate code{color:var(--accent)}
</style>
</head>
<body>
<div id="page">
  <header id="bar">
    <span id="dot" title="stream status"></span>
    <span id="title">netwatch <small>antgrid</small></span>
    <span class="seg" id="seg">
      <button data-t="all" class="on">all</button>
      <button data-t="relay">relay</button>
      <button data-t="local">local</button>
    </span>
    <button class="tog" id="dropsonly" title="Show only frames that never crossed">drops</button>
    <input id="q" placeholder="filter  type, channel, reason, detail, body" spellcheck="false" autocomplete="off">
    <button class="tog" id="pause" title="Freeze the view; frames keep arriving (Space)">pause</button>
    <button class="tog warn" id="bodies" title="Record loopback frame plaintext while this window is open">bodies</button>
    <button class="tog" id="remote" title="Ask the connected app to capture its own side">remote</button>
    <button class="tog" id="exp" title="Download what is on screen as JSONL">export</button>
    <button class="tog" id="clear" title="Empty this view; the host keeps its ring">clear</button>
    <span id="counts"></span>
  </header>
  <div id="note" hidden></div>
  <div id="err" hidden></div>
  <div id="wrap">
    <div id="main">
      <div id="head" class="cols">
        <div>time</div><div></div><div>wire</div><div>ch</div><div>kind</div>
        <div class="by">bytes</div><div>frame</div><div>type / detail</div>
      </div>
      <div id="scroll"><div id="rows"></div></div>
    </div>
    <aside id="detail" hidden></aside>
    <button id="jump" hidden>new frames below</button>
  </div>
</div>
<div id="gate" hidden></div>
<script nonce="__NONCE__">
(function(){
"use strict";

/* How many events this page keeps. Matches the host ring's default so a viewer
   opened early holds everything the host would still replay; the DOM cap is far
   lower because a scrolling build outruns any renderer long before it outruns
   memory. */
var MAX_EVENTS = 16384;
var MAX_ROWS = 3000;
var SESSION_KEY = "antgrid.netwatch.session";
/* The window every arm asks for. Same value the CLI uses, and clamped by the
   host either way; what comes back is what the heartbeat paces itself off. */
var ARM_TTL_MS = 300000;

var el = function(id){ return document.getElementById(id); };
var page = el("page"), gate = el("gate"), dot = el("dot"), rows = el("rows"),
    scroll = el("scroll"), detail = el("detail"), counts = el("counts"),
    note = el("note"), err = el("err"), jump = el("jump"), q = el("q");

var token = null;
var all = [];
var seen = Object.create(null);
var view = { transport:"all", drops:false, query:"", paused:false };
var follow = true, selected = null, dropped = 0, shed = 0, evicted = 0;
var queued = [], painting = false, everConnected = false;

/* ---- launch ------------------------------------------------------------ */

/* "#t=<ticket>;f=local;n=500". Semicolons rather than ampersands: this URL is
   handed to a browser through a shell on Windows, where "&" ends the command. */
function launchParams(){
  var out = {};
  location.hash.replace(/^#/, "").split(";").forEach(function(part){
    var i = part.indexOf("=");
    if (i > 0) { try { out[part.slice(0,i)] = decodeURIComponent(part.slice(i+1)); } catch (e) {} }
  });
  return out;
}
var launch = launchParams();
/* Stripped before anything can await: the ticket is spent within the second,
   but the URL in the address bar outlives the tab. */
if (location.hash) history.replaceState(null, "", location.pathname);

function line(text, cls){
  var d = document.createElement("div");
  if (cls) d.className = cls;
  d.textContent = text;
  return d;
}
function codeLine(before, code, after){
  var d = document.createElement("div");
  d.appendChild(document.createTextNode(before));
  var c = document.createElement("code");
  c.textContent = code;
  d.appendChild(c);
  if (after) d.appendChild(document.createTextNode(after));
  return d;
}
function showExpired(){
  page.hidden = true;
  gate.hidden = false;
  gate.replaceChildren(
    line("This viewer needs a fresh launch link.", "b"),
    line(""),
    codeLine("Run ", "antgrid watch --ui", " on this machine to open a new window."),
    line(""),
    line("A launch ticket is single-use and short-lived on purpose: the URL it"),
    line("rides in outlives the tab, in browser history and in anything you paste.")
  );
}

function fail(message){ err.hidden = false; err.textContent = message; }
function clearFail(){ err.hidden = true; err.textContent = ""; }

/* ---- sanitising -------------------------------------------------------- */

/* Peer-supplied text, rendered for a human. Control characters cannot execute
   in a document the way they can in a terminal, but a raw newline breaks the row
   grid and the bidi overrides genuinely reorder a line so it reads as a
   different message type than the one recorded. Both are dropped here; the
   export keeps every event exactly as it arrived. */
var STRIP = /[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;
var STRIP_KEEP_NL = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;

function clean(value, max){
  var s = (typeof value === "string" ? value : String(value)).replace(STRIP, "");
  if (max && s.length > max) s = s.slice(0, max) + "…";
  return s;
}
function cleanBody(value){ return String(value).replace(STRIP_KEEP_NL, ""); }

/* ---- formatting -------------------------------------------------------- */

function pad(n, w){ var s = String(n); while (s.length < w) s = "0" + s; return s; }
function clock(at){
  var d = new Date(at);
  return pad(d.getHours(),2) + ":" + pad(d.getMinutes(),2) + ":" + pad(d.getSeconds(),2) +
         "." + pad(d.getMilliseconds(),3);
}
function bytes(n){
  if (typeof n !== "number") return "";
  if (n < 1024) return n + "B";
  if (n < 1048576) return (n/1024).toFixed(1) + "K";
  return (n/1048576).toFixed(1) + "M";
}
/* An event naming no transport is read as relay: the field postdates the
   relay-only capture, so everything without it got here over the relay. */
function wireOf(ev){ return ev.transport === "local" ? "local" : "relay"; }
function channelOf(ev){
  return ev.channel === "preview" ? "prev" : ev.channel === "control" ? "ctrl" : "—";
}
function detailOf(ev){
  var parts = [];
  if (ev.streamId) parts.push("s:" + clean(ev.streamId, 8));
  if (ev.reason) parts.push(clean(ev.reason, 48));
  if (ev.detail && typeof ev.detail === "object") {
    Object.keys(ev.detail).forEach(function(k){
      parts.push(clean(k, 24) + "=" + clean(ev.detail[k], 48));
    });
  }
  return parts.join("  ");
}

/* ---- filtering --------------------------------------------------------- */

function matches(ev){
  if (view.transport !== "all" && wireOf(ev) !== view.transport) return false;
  if (view.drops && ev.kind !== "drop") return false;
  if (!view.query) return true;
  var hay = (ev.msgType || "") + " " + ev.kind + " " + (ev.channel || "") + " " +
            (ev.reason || "") + " " + (ev.frameId || "") + " " + wireOf(ev) + " " +
            detailOf(ev) + " " + (ev.body || "");
  return hay.toLowerCase().indexOf(view.query) !== -1;
}

/* ---- rendering --------------------------------------------------------- */

function cell(cls, text){
  var d = document.createElement("div");
  d.className = cls;
  d.textContent = text;
  return d;
}

function rowFor(ev){
  var drop = ev.kind === "drop";
  var r = document.createElement("div");
  r.className = "r" + (drop ? " drop" : "") + (ev.origin === "app" ? " fromapp" : "");
  r.__ev = ev;

  var c = document.createElement("div");
  c.className = "cols";
  c.appendChild(cell("t dim", clock(ev.at)));
  c.appendChild(cell("d " + (drop ? "x" : ev.dir === "tx" ? "tx" : "rx"),
                     drop ? "×" : ev.dir === "tx" ? "→" : "←"));
  var wire = wireOf(ev);
  var w = cell("tr " + wire, wire);
  if (ev.origin === "app") w.title = "recorded by the app and shipped over the relay";
  c.appendChild(w);
  c.appendChild(cell("ch dim", channelOf(ev)));
  c.appendChild(cell("kd dim", drop ? "DROP" : clean(ev.kind, 9)));
  c.appendChild(cell("by", bytes(ev.bytes)));
  c.appendChild(cell("fr", clean(ev.frameId || "", 12)));

  var tail = document.createElement("div");
  tail.className = "ty";
  tail.textContent = clean(ev.msgType || "", 60);
  var d = detailOf(ev);
  if (d) {
    var sp = document.createElement("span");
    sp.className = "det";
    sp.textContent = (ev.msgType ? "  " : "") + d;
    tail.appendChild(sp);
  }
  c.appendChild(tail);
  r.appendChild(c);

  if (typeof ev.body === "string") {
    var b = document.createElement("div");
    b.className = "bodyline";
    b.textContent = clean(ev.body.replace(/\s+/g, " "), 400);
    r.appendChild(b);
  }
  return r;
}

function trimRows(){
  var over = rows.childElementCount - MAX_ROWS;
  for (var i = 0; i < over; i++) rows.removeChild(rows.firstChild);
}
function atBottom(){
  return scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 24;
}

function append(list){
  var frag = document.createDocumentFragment(), added = 0;
  for (var i = 0; i < list.length; i++) {
    if (!matches(list[i])) continue;
    frag.appendChild(rowFor(list[i]));
    added++;
  }
  if (!added) return;
  rows.appendChild(frag);
  trimRows();
  if (follow) scroll.scrollTop = scroll.scrollHeight;
  else jump.hidden = false;
}

function rebuild(){
  rows.replaceChildren();
  var keep = [];
  for (var i = all.length - 1; i >= 0 && keep.length < MAX_ROWS; i--) {
    if (matches(all[i])) keep.push(all[i]);
  }
  keep.reverse();
  var frag = document.createDocumentFragment();
  for (var j = 0; j < keep.length; j++) frag.appendChild(rowFor(keep[j]));
  rows.appendChild(frag);
  if (follow) scroll.scrollTop = scroll.scrollHeight;
  paintCounts();
}

function paintCounts(){
  var bits = [rows.childElementCount + " shown", all.length + " held"];
  if (dropped) bits.push(dropped + " drops");
  if (shed) bits.push(shed + " shed");
  if (evicted) bits.push(evicted + " evicted");
  counts.textContent = bits.join("  ·  ");
}

function schedulePaint(){
  if (painting) return;
  painting = true;
  requestAnimationFrame(function(){
    painting = false;
    var batch = queued;
    queued = [];
    /* A paused view drops its batch rather than banking it: the events are in
       "all" either way, and unpausing rebuilds from there. Banking them instead
       meant a pause held through a scrolling build handed the renderer tens of
       thousands of rows to construct in one frame at the moment of release. */
    if (!view.paused) append(batch);
    paintCounts();
  });
}

function mark(text){
  var m = document.createElement("div");
  m.className = "mark";
  m.textContent = text;
  rows.appendChild(m);
  trimRows();
  if (follow) scroll.scrollTop = scroll.scrollHeight;
}

/* ---- detail ------------------------------------------------------------ */

var FIELDS = ["seq","dir","kind","transport","channel","streamId","msgType","frameId",
              "bytes","reason","origin"];

function showDetail(ev){
  detail.hidden = false;
  detail.replaceChildren();

  var h = document.createElement("h2");
  var nm = document.createElement("span");
  nm.className = "nm";
  nm.textContent = clean(ev.msgType || ev.kind, 60);
  h.appendChild(nm);
  var copy = document.createElement("button");
  copy.textContent = "copy json";
  copy.addEventListener("click", function(){
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(JSON.stringify(ev, null, 2)).then(function(){
      copy.textContent = "copied";
      setTimeout(function(){ copy.textContent = "copy json"; }, 1200);
    }, function(){});
  });
  h.appendChild(copy);
  var close = document.createElement("button");
  close.textContent = "close";
  close.addEventListener("click", clearSelection);
  h.appendChild(close);
  detail.appendChild(h);

  var dl = document.createElement("dl");
  dl.className = "kv";
  var add = function(k, v){
    var dt = document.createElement("dt"); dt.textContent = k;
    var dd = document.createElement("dd"); dd.textContent = v;
    dl.appendChild(dt); dl.appendChild(dd);
  };
  /* toISOString THROWS on an unrepresentable date, and an event shipped in by a
     peer reaches the ring with fields this page never validated. One bad row
     must not be the reason the detail pane stops opening for every other. */
  try { add("at", new Date(ev.at).toISOString()); } catch (e) { add("at", String(ev.at)); }
  FIELDS.forEach(function(k){
    if (ev[k] !== undefined && ev[k] !== null) add(k, clean(ev[k], 200));
  });
  if (ev.detail && typeof ev.detail === "object") {
    Object.keys(ev.detail).forEach(function(k){ add(clean(k, 24), clean(ev.detail[k], 200)); });
  }
  detail.appendChild(dl);

  if (typeof ev.body === "string") {
    var pre = document.createElement("pre");
    pre.id = "body";
    pre.textContent = cleanBody(ev.body);
    detail.appendChild(pre);
  } else {
    var hint = document.createElement("div");
    hint.id = "bodyh";
    hint.textContent = "no payload recorded — arm bodies to capture loopback plaintext";
    detail.appendChild(hint);
  }
}

function clearSelection(){
  if (selected) selected.classList.remove("sel");
  selected = null;
  detail.hidden = true;
  detail.replaceChildren();
}

rows.addEventListener("click", function(e){
  var r = e.target.closest ? e.target.closest(".r") : null;
  if (!r || !r.__ev) return;
  if (selected) selected.classList.remove("sel");
  selected = r;
  r.classList.add("sel");
  showDetail(r.__ev);
});

/* ---- ingest ------------------------------------------------------------ */

/* On a reconnect the host replays its ring, which overlaps what is already
   here. (origin, seq, at) is unique per recorded frame and survives a recorder
   restarting its counter, which a bare seq comparison would not. */
function fresh(ev){
  var key = (ev.origin || "brg") + ":" + ev.seq + ":" + ev.at;
  if (seen[key]) return false;
  seen[key] = 1;
  return true;
}

function ingest(ev){
  if (!fresh(ev)) return;
  all.push(ev);
  if (all.length > MAX_EVENTS) {
    all.splice(0, all.length - MAX_EVENTS);
    /* The map would otherwise grow for the life of the window. Dropping it
       wholesale can only re-admit an event this page has already forgotten,
       which is one no replay is going to offer again. */
    seen = Object.create(null);
  }
  if (ev.kind === "drop") dropped++;
  queued.push(ev);
  schedulePaint();
}

/* ---- stream ------------------------------------------------------------ */

function setStatus(kind, title){
  dot.className = kind;
  dot.title = title;
}

/* fetch rather than EventSource, which cannot set a header: this is the only
   shape in which the session token never appears in a URL, and therefore never
   in history, a referrer or a screenshot of the address bar. */
async function readStream(){
  var limit = everConnected ? 400 : (launch.n ? Number(launch.n) : 400);
  if (!isFinite(limit) || limit < 0) limit = 400;
  var res = await fetch("/netwatch?limit=" + limit + "&follow=1", {
    headers: { authorization: "Bearer " + token },
    cache: "no-store"
  });
  if (res.status === 401) {
    token = null;
    try { sessionStorage.removeItem(SESSION_KEY); } catch (e) {}
    throw new Error("unauthorized");
  }
  if (!res.ok || !res.body) throw new Error("HTTP " + res.status);

  clearFail();
  setStatus("live", "streaming from the host");
  if (everConnected) mark("reconnected");
  everConnected = true;

  var reader = res.body.getReader();
  var dec = new TextDecoder();
  var buf = "";
  for (;;) {
    var chunk = await reader.read();
    if (chunk.done) break;
    buf += dec.decode(chunk.value, { stream: true });
    var i;
    while ((i = buf.indexOf("\n\n")) !== -1) {
      var block = buf.slice(0, i);
      buf = buf.slice(i + 2);
      if (block.charAt(0) === ":") continue;
      var name = null, data = [];
      block.split("\n").forEach(function(l){
        if (l.indexOf("event:") === 0) name = l.slice(6).trim();
        else if (l.indexOf("data:") === 0) data.push(l.slice(5).trim());
      });
      if (!data.length) continue;
      var payload;
      try { payload = JSON.parse(data.join("\n")); } catch (e) { continue; }
      if (name === "replayed") {
        evicted = payload.evicted || 0;
        var missed = (payload.buffered || 0) - (payload.replayed || 0);
        mark("live" + (missed > 0 ? "  ·  " + missed + " older buffered events not replayed" : ""));
        continue;
      }
      if (name === "shed") {
        shed += payload.dropped || 0;
        mark(payload.dropped + " events dropped — this reader is behind the capture");
        continue;
      }
      ingest(payload);
    }
  }
}

async function run(){
  var backoff = 400;
  for (;;) {
    try {
      await readStream();
      backoff = 400;
      setStatus("retry", "stream ended, reconnecting");
    } catch (e) {
      var why = e && e.message ? e.message : String(e);
      if (!token) { setStatus("dead", "unauthorized"); showExpired(); return; }
      setStatus("retry", why);
      fail("lost the host — retrying (" + clean(why, 80) + ")");
    }
    await new Promise(function(r){ setTimeout(r, backoff); });
    backoff = Math.min(backoff * 2, 5000);
  }
}

/* ---- arming ------------------------------------------------------------ */

var arms = { bodies:{ on:false, timer:null }, remote:{ on:false, timer:null } };

function armRequest(which, on){
  if (which === "bodies") {
    return { id:"ui-arm", type:"netwatch:local", bodies:on, ttlMs: on ? ARM_TTL_MS : 0 };
  }
  var req = { id:"ui-arm", type:"netwatch:remote", enabled:on };
  if (on) req.ttlMs = ARM_TTL_MS;
  return req;
}

async function postArm(which, on, keepalive){
  var opts = {
    method: "POST",
    headers: { authorization: "Bearer " + token, "content-type": "application/json" },
    body: JSON.stringify(armRequest(which, on))
  };
  if (keepalive) opts.keepalive = true;
  var res = await fetch("/netwatch/ui/arm", opts);
  var reply = null;
  try { reply = await res.json(); } catch (e) {}
  if (!res.ok || !reply || !reply.ok) {
    throw new Error(reply && reply.error && reply.error.message ? reply.error.message
                                                                : "HTTP " + res.status);
  }
  return reply;
}

/* Pace the heartbeat off the window the host GRANTED, not the one asked for:
   the host clamps, and a renewal that believed it was early would let the
   window close underneath it. */
function schedule(which, ttlMs){
  var a = arms[which];
  if (a.timer) clearTimeout(a.timer);
  a.timer = setTimeout(function(){
    postArm(which, true, false).then(function(reply){
      schedule(which, reply.ttlMs);
    }, function(e){
      setArm(which, false);
      fail(which + " capture lapsed — " + clean(e.message, 80));
    });
  }, Math.max(1000, Math.floor((ttlMs || ARM_TTL_MS) * 0.4)));
}

function setArm(which, on){
  var a = arms[which];
  a.on = on;
  if (!on && a.timer) { clearTimeout(a.timer); a.timer = null; }
  el(which).classList.toggle("on", on);
  note.hidden = !arms.bodies.on;
  if (arms.bodies.on) {
    note.textContent = "bodies armed — loopback frames from now carry their plaintext. " +
      "Credential-bearing types stay redacted; everything else is in this window, and in any export.";
  }
}

function toggleArm(which){
  var btn = el(which);
  var want = !arms[which].on;
  btn.classList.add("busy");
  postArm(which, want, false).then(function(reply){
    clearFail();
    setArm(which, want);
    if (want) schedule(which, reply.ttlMs);
    if (want && which === "remote") {
      mark("remote capture armed — the app records from now, not retrospectively");
    }
  }, function(e){
    fail("could not " + (want ? "arm " : "disarm ") + which + " — " + clean(e.message, 120));
  }).then(function(){ btn.classList.remove("busy"); });
}

/* A closed window is the ordinary way to stop watching, and the host's dead-man
   TTL is what covers a crash. This only makes the common case immediate rather
   than up to a window late. */
window.addEventListener("pagehide", function(){
  if (!token) return;
  Object.keys(arms).forEach(function(which){
    if (arms[which].on) { try { postArm(which, false, true); } catch (e) {} }
  });
});

/* ---- export ------------------------------------------------------------ */

function exportJsonl(){
  var list = [];
  for (var i = 0; i < all.length; i++) if (matches(all[i])) list.push(all[i]);
  if (!list.length) { fail("nothing to export under the current filter"); return; }
  var text = list.map(function(e){ return JSON.stringify(e); }).join("\n") + "\n";
  var url = URL.createObjectURL(new Blob([text], { type: "application/x-ndjson" }));
  var d = new Date();
  var a = document.createElement("a");
  a.href = url;
  a.download = "netwatch-" + d.getFullYear() + pad(d.getMonth()+1,2) + pad(d.getDate(),2) + "-" +
               pad(d.getHours(),2) + pad(d.getMinutes(),2) + pad(d.getSeconds(),2) + ".jsonl";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(function(){ URL.revokeObjectURL(url); }, 10000);
}

/* ---- controls ---------------------------------------------------------- */

el("seg").addEventListener("click", function(e){
  var b = e.target.closest ? e.target.closest("button") : null;
  if (!b) return;
  view.transport = b.getAttribute("data-t");
  Array.prototype.forEach.call(el("seg").children, function(c){ c.classList.toggle("on", c === b); });
  rebuild();
});
el("dropsonly").addEventListener("click", function(){
  view.drops = !view.drops;
  el("dropsonly").classList.toggle("on", view.drops);
  rebuild();
});
var qTimer = null;
q.addEventListener("input", function(){
  if (qTimer) clearTimeout(qTimer);
  qTimer = setTimeout(function(){
    view.query = q.value.trim().toLowerCase();
    rebuild();
  }, 90);
});
el("pause").addEventListener("click", function(){
  view.paused = !view.paused;
  el("pause").classList.toggle("on", view.paused);
  if (!view.paused) rebuild();
});
el("bodies").addEventListener("click", function(){ toggleArm("bodies"); });
el("remote").addEventListener("click", function(){ toggleArm("remote"); });
el("exp").addEventListener("click", exportJsonl);
el("clear").addEventListener("click", function(){
  all = []; seen = Object.create(null); queued = [];
  dropped = 0; shed = 0;
  clearSelection();
  rebuild();
});

scroll.addEventListener("scroll", function(){
  follow = atBottom();
  if (follow) jump.hidden = true;
});
jump.addEventListener("click", function(){
  follow = true;
  jump.hidden = true;
  scroll.scrollTop = scroll.scrollHeight;
});

document.addEventListener("keydown", function(e){
  var typing = e.target === q;
  if (e.key === "/" && !typing) { e.preventDefault(); q.focus(); q.select(); return; }
  if (e.key === "Escape") { if (typing) q.blur(); else clearSelection(); return; }
  if (e.key === " " && !typing) { e.preventDefault(); el("pause").click(); }
});

/* ---- boot -------------------------------------------------------------- */

async function obtainToken(){
  var stored = null;
  try { stored = sessionStorage.getItem(SESSION_KEY); } catch (e) {}
  if (launch.t) {
    try {
      var res = await fetch("/netwatch/ui/session", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ ticket: launch.t })
      });
      if (res.ok) {
        var j = await res.json();
        if (j && j.token) {
          try { sessionStorage.setItem(SESSION_KEY, j.token); } catch (e) {}
          return j.token;
        }
      }
    } catch (e) {}
  }
  /* A reload has no ticket left to spend — the fragment was stripped and the
     ticket burned on the first load — so the stored session is what carries a
     window across F5. It dies with the tab, which is the lifetime we want. */
  return stored;
}

(async function boot(){
  if (launch.f === "local" || launch.f === "relay") {
    view.transport = launch.f;
    Array.prototype.forEach.call(el("seg").children, function(c){
      c.classList.toggle("on", c.getAttribute("data-t") === launch.f);
    });
  }
  token = await obtainToken();
  if (!token) { showExpired(); return; }
  paintCounts();
  run();
})();

})();
</script>
</body>
</html>`;

/**
 * The viewer, with a per-response nonce bound into both the CSP header and the
 * two inline blocks.
 *
 * The page is entirely self-authored and loads nothing from anywhere, so the
 * policy is `'none'` by default and the nonce is the only thing widening it —
 * which means an injected `<script>` could not run even if a future edit let one
 * past the textContent-only rule the page is written to.
 */
export function netwatchUiPage(nonce: string): { html: string; csp: string } {
  return {
    html: PAGE.replace(/__NONCE__/g, nonce),
    csp: [
      "default-src 'none'",
      `script-src 'nonce-${nonce}'`,
      `style-src 'nonce-${nonce}'`,
      "connect-src 'self'",
      "base-uri 'none'",
      "form-action 'none'",
      "frame-ancestors 'none'",
    ].join("; "),
  };
}
