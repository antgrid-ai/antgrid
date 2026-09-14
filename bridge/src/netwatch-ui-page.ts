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
 * Two feeds share this one document — netwatch's relay/loopback frames and
 * modelwatch's headless model calls — switched by a tab rather than served as a
 * second page, because they share a session and a credential. Everything
 * stateful is duplicated per feed on purpose rather than made generic: the two
 * must reconnect, dedup and arm independently, and two small parallel code
 * paths are far easier to keep that way than one path parameterised over both.
 *
 * Every field rendered here was written by a peer — a message type from the
 * relay, a body from an agent's stdout, a usage envelope a vendor CLI reported —
 * so NOTHING in this page may reach the DOM as markup. Values go in through
 * textContent only; `clean()` additionally drops control characters and bidi
 * overrides, which cannot execute but can silently reorder a line so it reads as
 * a different frame than the one recorded. A model-call event is additionally
 * untrusted in its SHAPE, not just its text: most of its fields are absent until
 * a later phase fills them in, and nothing between the ring and this page
 * validates one, so the calls-feed code never assumes a field is present or
 * well-typed before reading it.
 */
const PAGE = String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>antgrid capture</title>
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
#feedtabs button.err{color:var(--drop)}
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

/* ---- tab strip and the model-calls feed. Its selectors are its own: the two
   feeds are independent, so styling one is never done by reaching into the
   netwatch pane's rules above. ---- */
#tabbar{display:flex;align-items:center;gap:8px;padding:6px 10px;background:var(--panel);
        border-bottom:1px solid var(--line);flex:none}
#apptitle{font-weight:600;letter-spacing:.02em}
#apptitle small{color:var(--dim);font-weight:400}
.pane{display:flex;flex-direction:column;flex:1;min-height:0}

#mcbar{display:flex;align-items:center;gap:8px;padding:6px 10px;background:var(--panel);
       border-bottom:1px solid var(--line);flex-wrap:wrap;flex:none}
#mcdot{width:8px;height:8px;border-radius:50%;background:var(--dimmer);flex:none}
#mcdot.live{background:var(--rx);box-shadow:0 0 6px var(--rx)}
#mcdot.retry{background:var(--warn)}
#mcdot.dead{background:var(--drop)}
#mctitle{font-weight:600;letter-spacing:.02em}
#mctitle small{color:var(--dim);font-weight:400}
#mcq{flex:1;min-width:140px;background:var(--bg);border:1px solid var(--line);border-radius:5px;
     padding:3px 8px;font-family:var(--mono)}
#mcq:focus{outline:none;border-color:var(--accent)}
#mccounts{color:var(--dim);font-family:var(--mono);white-space:nowrap;margin-left:auto}
#mcnote{padding:4px 10px;background:#2a2110;color:var(--warn);border-bottom:1px solid var(--line);
        font-family:var(--mono);flex:none}
#mcerr{padding:4px 10px;background:#2a1414;color:var(--drop);border-bottom:1px solid var(--line);
       font-family:var(--mono);flex:none}
#mcwrap{display:flex;flex:1;min-height:0;position:relative}
#mcmain{display:flex;flex-direction:column;flex:1;min-width:0}

.mcols{display:grid;grid-template-columns:90px 76px 150px 130px 42px 128px 92px minmax(0,1fr);
       gap:10px;padding:0 10px;font-family:var(--mono);white-space:nowrap}
#mchead{background:var(--panel);border-bottom:1px solid var(--line);color:var(--dimmer);
        padding-top:3px;padding-bottom:3px;text-transform:uppercase;font-size:10px;
        letter-spacing:.05em;flex:none}
#mcscroll{flex:1;overflow-y:auto;overflow-x:hidden;min-height:0}
#mcrows{padding-bottom:8px}
.r .mcols>div{overflow:hidden;text-overflow:ellipsis}

.oc-good{color:var(--rx)}
.oc-bad{color:var(--drop)}
.oc-warn{color:var(--warn)}
.oc-info{color:var(--tx)}
.oc-dim{color:var(--dim)}
.bodyline.mcx{padding-left:10px}

#mcjump{position:absolute;left:50%;transform:translateX(-50%);bottom:16px;background:var(--accent);
        color:#08111f;border:0;border-radius:14px;padding:5px 14px;cursor:pointer;font-weight:600;
        box-shadow:0 4px 14px rgba(0,0,0,.5)}

#mcdetail{width:400px;flex:none;border-left:1px solid var(--line);background:var(--panel);
          overflow-y:auto;padding:10px}
#mcdetail h2{margin:0 0 8px;font-size:12px;color:var(--dim);font-weight:600;display:flex;
             align-items:center;gap:6px}
#mcdetail h2 button{background:none;border:1px solid var(--line);border-radius:4px;
                    padding:2px 7px;color:var(--dim);cursor:pointer;font-weight:400}
#mcdetail h2 .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;
                 font-family:var(--mono);color:var(--fg)}
.tb{margin:10px 0 0;padding:8px;background:var(--bg);border:1px solid var(--line);
    border-radius:5px;font-family:var(--mono);white-space:pre-wrap;overflow-wrap:anywhere;
    max-height:30vh;overflow:auto}
.tbl{margin:10px 0 0;color:var(--dimmer);font-family:var(--mono)}
</style>
</head>
<body>
<div id="page">
  <header id="tabbar">
    <span id="apptitle">antgrid <small>capture</small></span>
    <span class="seg" id="feedtabs">
      <button data-f="nw" class="on">netwatch</button>
      <button data-f="mc">calls</button>
    </span>
  </header>
  <div id="nwPane" class="pane">
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
  <div id="mcPane" class="pane" hidden>
    <header id="mcbar">
      <span id="mcdot" title="stream status"></span>
      <span id="mctitle">calls <small>antgrid</small></span>
      <span class="seg" id="mcpurpose">
        <button data-p="all" class="on">all</button>
        <button data-p="title">title</button>
        <button data-p="decision">decision</button>
        <button data-p="extraction">extraction</button>
      </span>
      <input id="mcq" placeholder="filter  purpose, tool, model, outcome" spellcheck="false" autocomplete="off">
      <button class="tog" id="mcpause" title="Freeze the view; calls keep arriving (Space)">pause</button>
      <button class="tog warn" id="mcprompts" title="Record the scaffold, goal and a context digest for headless model calls">prompts</button>
      <button class="tog" id="mcexp" title="Download what is on screen as JSONL">export</button>
      <button class="tog" id="mcclear" title="Empty this view; the host keeps its ring">clear</button>
      <span id="mccounts"></span>
    </header>
    <div id="mcnote"></div>
    <div id="mcerr" hidden></div>
    <div id="mcmarks" class="mark" hidden></div>
    <div id="mcwrap">
      <div id="mcmain">
        <div id="mchead" class="mcols">
          <div>time</div><div>purpose</div><div>agent</div><div>model</div>
          <div>#</div><div>wall / api</div><div>outcome</div><div>tokens</div>
        </div>
        <div id="mcscroll"><div id="mcrows"></div></div>
      </div>
      <aside id="mcdetail" hidden></aside>
      <button id="mcjump" hidden>new calls below</button>
    </div>
  </div>
</div>
<div id="gate" hidden></div>
<script nonce="__NONCE__">
(function(){
"use strict";

/* How many events this page keeps. Matches the host ring's default so a viewer
   opened early holds everything the host would still replay; the DOM cap is far
   lower because a scrolling build outruns any renderer long before it outruns
   memory. Shared by both feeds — it bounds a count of held items, not anything
   about what either feed's items mean. */
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

var nwPane = el("nwPane"), mcPane = el("mcPane");
var mcDot = el("mcdot"), mcRows = el("mcrows"), mcScrollEl = el("mcscroll"),
    mcDetailEl = el("mcdetail"), mcCountsEl = el("mccounts"), mcNoteEl = el("mcnote"),
    mcErrEl = el("mcerr"), mcMarksEl = el("mcmarks"), mcJumpEl = el("mcjump"), mcQEl = el("mcq");
/* The "calls" tab button itself, so a dead feed can be seen from the netwatch
   tab — #mcdot and #mcerr both live inside #mcPane, which is exactly the pane
   that is hidden while the operator is looking at the other one. */
var mcTabBtn = el("feedtabs").querySelector('[data-f="mc"]');

/* The sentence #mcnote carries whenever prompts capture is OFF — the one
   boundary a viewer needs before ever touching the toggle: this page cannot
   reach the transcript/answer arm no matter what it POSTs. Shown from load
   rather than only after arming, because a viewer deciding whether to arm
   anything is exactly who needs to read it first. */
var MC_NOTE_BASE = "the transcript excerpt and the model's answer are captured only from the CLI " +
  "(antgrid calls --context) and cannot be armed from this page.";
mcNoteEl.textContent = MC_NOTE_BASE;

var token = null;
var all = [];
var seen = Object.create(null);
var view = { transport:"all", drops:false, query:"", paused:false };
var follow = true, selected = null, dropped = 0, shed = 0, evicted = 0;
var queued = [], painting = false, everConnected = false;

/* The calls feed's own state, deliberately never touching anything above.
   mcRecordsList holds RAW records (deduped, capped) exactly as they arrived —
   the source of truth for export and for the fold below — and is distinct from
   the folded Attempt objects mcFoldAll derives from it on every render. */
var mcRecordsList = [];
var mcSeen = Object.create(null);
var mcView = { purpose:"all", query:"", paused:false };
var mcFollow = true, mcSelected = null, mcShed = 0, mcEvicted = 0;
/* Whether anything actually ARRIVED since the last repaint. mcRebuild is the
   one paint path for this feed — a new record, a filter change, an unpause all
   run it — so without this the "new calls below" button would appear on a
   scrolled-up pane the moment someone typed in the filter box, asserting a
   backlog that does not exist. Netwatch keeps the two apart structurally: only
   its append() raises the button, never its rebuild(). */
var mcArrived = false;
var mcPainting = false, mcEverConnected = false;
var mcArms = { prompts: { on:false, timer:null } };

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
function mcFail(message){ mcErrEl.hidden = false; mcErrEl.textContent = message; }
function mcClearFail(){ mcErrEl.hidden = true; mcErrEl.textContent = ""; }

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
function mcSetStatus(kind, title){
  mcDot.className = kind;
  mcDot.title = title;
  // #mcdot lives inside #mcPane, invisible while the netwatch tab is active —
  // without this, a dead calls feed is a silent hole until someone happens to
  // click over and look.
  if (mcTabBtn) mcTabBtn.classList.toggle("err", kind === "retry" || kind === "dead");
}

/* fetch rather than EventSource, which cannot set a header: this is the only
   shape in which the session token never appears in a URL, and therefore never
   in history, a referrer or a screenshot of the address bar. Both feeds share
   this rationale and the one session it buys — see mcReadStream below. */
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
    // This timer has already fired — it is spent the moment it runs — so
    // nothing later may find it still sitting in a.timer and skip clearing it.
    a.timer = null;
    if (!a.on) return; // disarmed while this renewal was in flight
    postArm(which, true, false).then(function(reply){
      if (!a.on) return; // disarmed while the POST itself was in flight
      schedule(which, reply.ttlMs);
    }, function(e){
      if (!a.on) return;
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

/* ============================================================================
   ---- model calls ----------------------------------------------------------
   The /modelwatch feed. Independent of everything above: its own state, its
   own DOM, its own stream and its own arm. The one thing it shares is the
   session token — one ticket buys a session that reads both feeds, and a
   session that is no longer valid is no longer valid for either of them.

   Every record read here was written by this machine's own headless spawns,
   but the SHAPE is still not trusted: nothing between the ring and this page
   validates a record, so a hostile or merely buggy write arrives looking
   exactly like a legitimate one and nothing below assumes a field is present
   or well-typed before reading it. Rendering
   is folded from raw records the way the CLI folds them — joined by callId and
   attempt, later records filling in fields a start record couldn't know — but
   unlike the CLI's batch-until-outcome model, a record is rendered the moment
   it arrives: a start with no end yet is its own live row ("in flight"),
   updated in place as its end and outcome land, because an operator watching
   this page wants to see a call that is still running, not wait for it to
   finish.
   ============================================================================ */

/* ---- fold ---------------------------------------------------------------- */

function shallowCopy(obj){
  var out = {};
  for (var k in obj) { if (Object.prototype.hasOwnProperty.call(obj, k)) out[k] = obj[k]; }
  return out;
}

/* Keyed by callId AND attempt, as the CLI keys it — one row per attempt, a
   retry's own row rather than merged into the call it retried. A callId that
   is missing or not a string never collides two unrelated malformed records
   into one row: it falls back to this record's own seq, which the host
   guarantees is unique. */
function mcAttemptKey(ev){
  var callId = (typeof ev.callId === "string" && ev.callId) ? ev.callId : ("seq:" + ev.seq);
  var attempt = (typeof ev.attempt === "number" && isFinite(ev.attempt)) ? ev.attempt : 1;
  return callId + "#" + attempt;
}

/* The fields a later record may fill in. Mirrors modelwatch.ts's ModelCallEvent
   minus the identity fields (callId/attempt/purpose/requestedTool/actualTool/
   reach), which only the FIRST record for a key gets to set. */
var MC_FOLD_FIELDS = ["requestedModel", "actualModel", "terminalId", "conversationId", "projectId",
  "wallMs", "apiMs", "budgetMs", "remainingMs", "exitCode", "timedOut", "outcome", "outcomeDetail",
  "promptChars", "stdoutChars", "prompt", "stdout", "usage"];

/* Fold one record into the attempt it describes, mutating a copy rather than
   the record itself: base may already be referenced by a rendered row, and a
   later record filling in a field must never make an object a subscriber
   already holds appear to change under it. An absent field never overwrites a
   present one — the three phases are additive by construction. */
function mcFoldInto(base, ev){
  var next = base ? shallowCopy(base) : {
    callId: typeof ev.callId === "string" ? ev.callId : "",
    attempt: (typeof ev.attempt === "number" && isFinite(ev.attempt)) ? ev.attempt : 1,
    purpose: typeof ev.purpose === "string" ? ev.purpose : "?",
    at: (typeof ev.at === "number" && isFinite(ev.at)) ? ev.at : Date.now(),
    requestedTool: typeof ev.requestedTool === "string" ? ev.requestedTool : "",
    actualTool: typeof ev.actualTool === "string" ? ev.actualTool : "",
    reach: typeof ev.reach === "string" ? ev.reach : "",
    ended: false
  };
  next.ended = next.ended || ev.phase === "end";
  for (var i = 0; i < MC_FOLD_FIELDS.length; i++) {
    var k = MC_FOLD_FIELDS[i];
    if (ev[k] !== undefined) next[k] = ev[k];
  }
  return next;
}

/* Recomputed from mcRecordsList on every render rather than maintained
   incrementally: a few hundred calls a day means at most a few thousand
   records held at once, so refolding the whole list is cheap, and a derived
   value can never drift out of sync with the records it was derived from —
   there is no second data structure for an evicted record or a malformed one
   to leave stranded. */
function mcFoldAll(){
  var map = Object.create(null);
  var order = [];
  for (var i = 0; i < mcRecordsList.length; i++) {
    try {
      var ev = mcRecordsList[i];
      if (!ev || typeof ev !== "object") continue;
      var key = mcAttemptKey(ev);
      var existing = map[key];
      map[key] = mcFoldInto(existing, ev);
      if (!existing) order.push(key);
    } catch (e) {
      // One bad record must not break the fold for every other one.
    }
  }
  var out = [];
  for (var j = 0; j < order.length; j++) out.push(map[order[j]]);
  return out;
}

/* ---- filtering ------------------------------------------------------------
   Reads only fields that exist identically on a raw record and on a folded
   Attempt, so the same function filters both the rendered rows and the export
   (which reads records before they are folded). */

function mcHaystack(a){
  try {
    var bits = [a.purpose, a.requestedTool, a.actualTool, a.requestedModel, a.actualModel,
                a.outcome, a.outcomeDetail, a.callId, a.terminalId, a.reach];
    var out = "";
    for (var i = 0; i < bits.length; i++) {
      var v = bits[i];
      out += " " + (typeof v === "string" ? v : (v === undefined || v === null ? "" : String(v)));
    }
    return out;
  } catch (e) {
    return "";
  }
}

function mcMatches(a){
  try {
    if (mcView.purpose !== "all" && a.purpose !== mcView.purpose) return false;
    if (!mcView.query) return true;
    return mcHaystack(a).toLowerCase().indexOf(mcView.query) !== -1;
  } catch (e) {
    return false;
  }
}

/* ---- formatting, agreeing with the CLI's semantics ------------------------
   antgrid calls is the reference: same rounding, same refusals to sum. See
   usageNote below for the one vocabulary this deliberately carries whole. */

function mcDuration(ms){
  if (typeof ms !== "number" || !isFinite(ms)) return "—";
  if (Math.abs(ms) < 1000) return Math.round(ms) + "ms";
  return (ms / 1000).toFixed(1) + "s";
}

function mcTokens(n){
  if (typeof n !== "number" || !isFinite(n)) return null;
  return n < 1000 ? String(n) : (n / 1000).toFixed(1) + "k";
}

/* Which agent ran, and which was asked for when they differ (a borrow bills a
   vendor the session did not pick). */
function mcToolCell(a){
  var req = typeof a.requestedTool === "string" ? a.requestedTool : "";
  var act = typeof a.actualTool === "string" ? a.actualTool : "";
  if (req === act) return clean(act, 20);
  return clean(req, 16) + "→" + clean(act, 16);
}

/* default is not a missing value: it is a call that named no model at all
   and ran on whatever this machine's CLI defaults to. */
function mcModelCell(a){
  var requested = (typeof a.requestedModel === "string" && a.requestedModel) ? clean(a.requestedModel, 16) : "default";
  var actual = typeof a.actualModel === "string" ? a.actualModel : "";
  if (!actual || actual === a.requestedModel) return requested;
  return requested + "→" + clean(actual, 16);
}

/* Matched on the outcome's WORDS rather than an enumerated list, exactly as
   the CLI does — the vocabulary belongs to the callers (handler/judge.ts, the
   title path's own), and a closed list here would silently call the next verb
   they invent a success. Keep in lockstep with UNUSABLE_OUTCOME_RE in
   cli/modelwatch.ts — the two are compared in netwatch-ui-modelcalls.test.ts. */
var MC_UNUSABLE_RE = /fail|timeout|reject|unparse|exhaust|unavailable|abandon|skip|no-judge/;
function mcAnswerWasUsable(outcome){
  return !MC_UNUSABLE_RE.test(outcome);
}

function mcRetryWasMoot(a){
  return typeof a.outcome === "string" && a.outcome !== "" && mcAnswerWasUsable(a.outcome);
}

/* The verdict, preferring what the caller made of the answer over how the
   process exited — see cli/modelwatch.ts's outcomeCell for why. */
function mcOutcomeCell(a){
  if (typeof a.outcome === "string" && a.outcome) {
    return { text: clean(a.outcome, 20), cls: mcAnswerWasUsable(a.outcome) ? "oc-good" : "oc-warn" };
  }
  if (a.timedOut === true) return { text: "timed out", cls: "oc-bad" };
  if (!a.ended) return { text: "in flight", cls: "oc-info" };
  if (typeof a.exitCode === "number" && a.exitCode !== 0) return { text: "exit " + a.exitCode, cls: "oc-warn" };
  return { text: "ran", cls: "oc-dim" };
}

/* Below this, a retry cannot land whatever the arithmetic says it is owed —
   same floor the CLI uses (RETRY_FLOOR_MS in cli/modelwatch.ts). Absence means
   "this call had no retry to starve", not "plenty left": only the
   shared-budget callers record it at all. */
var MC_RETRY_FLOOR_MS = 5000;
function mcRetryBudgetNote(a){
  if (typeof a.remainingMs !== "number" || !isFinite(a.remainingMs) || mcRetryWasMoot(a)) return null;
  if (a.remainingMs <= 0) return { text: "nothing left for a retry", cls: "oc-bad" };
  if (a.remainingMs < MC_RETRY_FLOOR_MS) {
    return { text: mcDuration(a.remainingMs) + " left for the retry — unreachable", cls: "oc-bad" };
  }
  return { text: mcDuration(a.remainingMs) + " left for the retry", cls: "dim" };
}

/* Carried whole from the CLI: same cells, same refusals to sum. Read/write
   cache tokens stay separate because they are priced separately; reasoning
   tokens appear only when nonzero because whether they double-count out is
   the vendor's own choice; money is tagged with its unit and never folded into
   anything, because the three CLIs report dollars, nothing, and fractional
   premium requests. numTurns and permissionDenials are deliberately left
   out of this cell (as the CLI leaves them out of its own) — they show up in
   the detail pane instead. */
function mcUsageNote(a){
  var u = a.usage;
  if (!u || typeof u !== "object") return null;
  var parts = [];
  var push = function(label, n){
    var t = mcTokens(n);
    if (t) parts.push(label + " " + t);
  };
  push("in", u.inputTokens);
  push("cache r", u.cacheReadTokens);
  push("cache w", u.cacheWriteTokens);
  push("out", u.outputTokens);
  if (u.reasoningTokens) push("reasoning", u.reasoningTokens);
  if (u.money && typeof u.money === "object" && typeof u.money.amount === "number") {
    parts.push(u.money.amount + " " + clean(u.money.unit, 20));
  }
  if (u.modelsBilled) parts.push(String(u.modelsBilled) + " models");
  return parts.length > 0 ? parts.join(" · ") : null;
}

/* ---- rendering ------------------------------------------------------------
   Eight columns: time, purpose, agent requested/actual, model, attempt,
   duration wall/api, outcome, tokens. The duration cell pairs wall with the
   vendor's own API time, where the CLI's pairs it with the budget — the budget
   is a column the CLI has and this row does not, and the leftover a retry
   inherits from it is carried by mcRetryBudgetNote instead.
   Left out of the row on purpose: the callId itself (the attempt marker plus
   adjacency is the whole of the grouping, same as the CLI's own "↳" — showing
   the id again would just repeat the join key), and the prompt/stdout text
   (multiple named parts of very different sensitivity, arm-gated and often
   long — squeezed into one inline line they would lose which part is which;
   the detail pane below renders them properly). */

function mcRowFor(a){
  var oc = mcOutcomeCell(a);
  var r = document.createElement("div");
  r.className = "r";
  r.__attempt = a;

  var c = document.createElement("div");
  c.className = "mcols";
  c.appendChild(cell("t dim", clock(typeof a.at === "number" ? a.at : Date.now())));
  c.appendChild(cell("dim", clean(a.purpose || "", 10)));
  var borrowed = typeof a.requestedTool === "string" && typeof a.actualTool === "string" &&
                 a.requestedTool !== a.actualTool;
  c.appendChild(cell(borrowed ? "" : "dim", mcToolCell(a)));
  var swapped = typeof a.actualModel === "string" && a.actualModel && a.actualModel !== a.requestedModel;
  c.appendChild(cell(swapped ? "" : "dim", mcModelCell(a)));
  var attemptNum = (typeof a.attempt === "number" && isFinite(a.attempt) && a.attempt > 0) ? a.attempt : 1;
  c.appendChild(cell("dim", attemptNum <= 1 ? " #1" : ("↳#" + attemptNum)));
  c.appendChild(cell(a.timedOut === true ? "oc-bad" : "dim", mcDuration(a.wallMs) + " / " + mcDuration(a.apiMs)));
  c.appendChild(cell(oc.cls, oc.text));
  c.appendChild(cell("dim", mcUsageNote(a) || ""));
  r.appendChild(c);

  var extras = [];
  var budget = mcRetryBudgetNote(a);
  if (budget) extras.push(budget);
  if (typeof a.outcomeDetail === "string" && a.outcomeDetail) extras.push({ text: clean(a.outcomeDetail, 96), cls: "oc-warn" });
  if (a.reach === "unavailable") extras.push({ text: "no headless entry", cls: "oc-warn" });
  if (a.ended && a.stdoutChars === 0) extras.push({ text: "no output", cls: "oc-warn" });
  if (typeof a.terminalId === "string" && a.terminalId) extras.push({ text: "t:" + clean(a.terminalId, 8), cls: "dim" });
  if (extras.length > 0) {
    var d = document.createElement("div");
    d.className = "bodyline mcx";
    for (var i = 0; i < extras.length; i++) {
      if (i > 0) d.appendChild(document.createTextNode("  ·  "));
      var sp = document.createElement("span");
      sp.className = extras[i].cls;
      sp.textContent = extras[i].text;
      d.appendChild(sp);
    }
    r.appendChild(d);
  }
  return r;
}

function mcAtBottom(){
  return mcScrollEl.scrollHeight - mcScrollEl.scrollTop - mcScrollEl.clientHeight < 24;
}

function mcPaintCounts(attemptCount){
  var bits = [mcRows.childElementCount + " shown", attemptCount + " calls", mcRecordsList.length + " records held"];
  if (mcShed) bits.push(mcShed + " shed");
  if (mcEvicted) bits.push(mcEvicted + " evicted");
  mcCountsEl.textContent = bits.join("  ·  ");
}

function mcRebuild(){
  var attempts = mcFoldAll();
  var keep = [];
  for (var i = attempts.length - 1; i >= 0 && keep.length < MAX_ROWS; i--) {
    try { if (mcMatches(attempts[i])) keep.push(attempts[i]); } catch (e) {}
  }
  keep.reverse();
  // Every row is rebuilt from scratch on every paint (the fold-in-place design
  // updates a call in place by replacing its whole row), so a selection tied to
  // the OLD node is about to be destroyed under it. Re-attach by the same key
  // mcFoldAll groups by, not by DOM identity, and refresh the open detail pane
  // to whatever this attempt looks like now — otherwise a call selected while
  // "in flight" would show its start-phase snapshot forever.
  var prevKey = (mcSelected && mcSelected.__attempt) ? mcAttemptKey(mcSelected.__attempt) : null;
  var reselected = null;
  var frag = document.createDocumentFragment();
  for (var j = 0; j < keep.length; j++) {
    try {
      var row = mcRowFor(keep[j]);
      if (prevKey !== null && mcAttemptKey(keep[j]) === prevKey) {
        row.classList.add("sel");
        reselected = row;
      }
      frag.appendChild(row);
    } catch (e) {}
  }
  mcRows.replaceChildren();
  mcRows.appendChild(frag);
  if (prevKey !== null) {
    if (reselected) {
      mcSelected = reselected;
      if (!mcDetailEl.hidden) mcShowDetail(reselected.__attempt);
    } else {
      // Filtered out or evicted since the last paint — nothing left to
      // reattach the selection to.
      mcClearSelection();
    }
  }
  if (mcFollow) mcScrollEl.scrollTop = mcScrollEl.scrollHeight;
  else if (mcArrived) mcJumpEl.hidden = false;
  mcArrived = false;
  mcPaintCounts(attempts.length);
}

function mcSchedulePaint(){
  if (mcPainting) return;
  mcPainting = true;
  requestAnimationFrame(function(){
    mcPainting = false;
    try {
      if (!mcView.paused) mcRebuild();
      else mcPaintCounts(mcFoldAll().length);
    } catch (e) {
      // A bad frame must not wedge every frame after it.
    }
  });
}

/* A NOTICE, not a row: mcRebuild() replaceChildren()s #mcrows on every paint
   (the fold-in-place design), so a mark planted there — including the one
   naming records this reader never got to see — is wiped by the very next
   arrival, sometimes before it is ever rendered. #mcmarks sits outside that
   container and mcRebuild never touches it, so the latest notice survives
   until the next one replaces it. */
function mcMark(text){
  mcMarksEl.hidden = false;
  mcMarksEl.textContent = text;
}

/* ---- detail ---------------------------------------------------------------
   Scalar fields the netwatch pane's FIELDS array does for frames. usage is
   an object, so it is spread into its own dt/dd pairs rather than named
   whole — the same reason modelwatch-log.ts's export allow-list cannot name
   usage either. */

var MC_FIELDS = ["callId", "purpose", "attempt", "requestedTool", "actualTool", "reach",
  "requestedModel", "actualModel", "terminalId", "conversationId", "projectId",
  "wallMs", "apiMs", "exitCode", "timedOut", "budgetMs", "remainingMs",
  "outcome", "outcomeDetail", "promptChars", "stdoutChars"];

var MC_USAGE_FIELDS = ["inputTokens", "cacheReadTokens", "cacheWriteTokens", "outputTokens",
  "reasoningTokens", "numTurns", "permissionDenials", "modelsBilled"];

function mcClearSelection(){
  if (mcSelected) mcSelected.classList.remove("sel");
  mcSelected = null;
  mcDetailEl.hidden = true;
  mcDetailEl.replaceChildren();
}

function mcShowDetail(a){
  try {
    mcDetailEl.hidden = false;
    mcDetailEl.replaceChildren();

    var h = document.createElement("h2");
    var nm = document.createElement("span");
    nm.className = "nm";
    nm.textContent = clean((a.purpose || "?") + "  " + mcToolCell(a), 60);
    h.appendChild(nm);
    var copy = document.createElement("button");
    copy.textContent = "copy json";
    copy.addEventListener("click", function(){
      if (!navigator.clipboard) return;
      var text;
      try { text = JSON.stringify(a, null, 2); } catch (e) { text = "{}"; }
      navigator.clipboard.writeText(text).then(function(){
        copy.textContent = "copied";
        setTimeout(function(){ copy.textContent = "copy json"; }, 1200);
      }, function(){});
    });
    h.appendChild(copy);
    var close = document.createElement("button");
    close.textContent = "close";
    close.addEventListener("click", mcClearSelection);
    h.appendChild(close);
    mcDetailEl.appendChild(h);

    var dl = document.createElement("dl");
    dl.className = "kv";
    var add = function(k, v){
      var dt = document.createElement("dt"); dt.textContent = k;
      var dd = document.createElement("dd"); dd.textContent = v;
      dl.appendChild(dt); dl.appendChild(dd);
    };
    try { add("at", new Date(a.at).toISOString()); } catch (e) { add("at", String(a.at)); }
    for (var i = 0; i < MC_FIELDS.length; i++) {
      var k = MC_FIELDS[i];
      if (a[k] !== undefined && a[k] !== null) add(k, clean(a[k], 200));
    }
    var u = a.usage;
    if (u && typeof u === "object") {
      for (var j = 0; j < MC_USAGE_FIELDS.length; j++) {
        var uk = MC_USAGE_FIELDS[j];
        if (u[uk] !== undefined && u[uk] !== null) add("usage." + uk, clean(u[uk], 60));
      }
      if (u.money && typeof u.money === "object") {
        add("usage.money", clean(u.money.amount, 20) + " " + clean(u.money.unit, 20));
      }
    }
    mcDetailEl.appendChild(dl);

    var addText = function(label, value){
      var lbl = document.createElement("div");
      lbl.className = "tbl";
      lbl.textContent = label;
      mcDetailEl.appendChild(lbl);
      var pre = document.createElement("pre");
      pre.className = "tb";
      pre.textContent = cleanBody(typeof value === "string" ? value : String(value));
      mcDetailEl.appendChild(pre);
    };
    var p = a.prompt;
    var wroteText = false;
    if (p && typeof p === "object") {
      if (typeof p.scaffold === "string") { addText("scaffold", p.scaffold); wroteText = true; }
      if (typeof p.goal === "string") { addText("goal", p.goal); wroteText = true; }
      if (typeof p.backlogChars === "number") { addText("backlog", p.backlogChars + " chars — never recorded"); wroteText = true; }
      if (p.context && typeof p.context === "object" && typeof p.context.sha256 === "string") {
        var chars = typeof p.context.chars === "number" ? p.context.chars : "?";
        addText("context", p.context.sha256.slice(0, 12) + "…  " + chars + " chars");
        wroteText = true;
      }
      if (typeof p.contextText === "string") { addText("ctx text", p.contextText); wroteText = true; }
    }
    if (typeof a.stdout === "string") { addText("answer", a.stdout); wroteText = true; }
    if (!wroteText) {
      var hint = document.createElement("div");
      hint.className = "tbl";
      hint.textContent = "no prompt or answer text recorded — arm prompts above for the scaffold " +
        "and goal; the transcript excerpt and the model's answer are recorded only from the CLI " +
        "(antgrid calls --context) and cannot be armed from this page";
      mcDetailEl.appendChild(hint);
    }
  } catch (e) {
    mcDetailEl.replaceChildren();
    var errLine = document.createElement("div");
    errLine.className = "tbl";
    errLine.textContent = "could not render this record";
    mcDetailEl.appendChild(errLine);
  }
}

mcRows.addEventListener("click", function(e){
  var r = e.target.closest ? e.target.closest(".r") : null;
  if (!r || !r.__attempt) return;
  if (mcSelected) mcSelected.classList.remove("sel");
  mcSelected = r;
  r.classList.add("sel");
  mcShowDetail(r.__attempt);
});

/* ---- ingest ---------------------------------------------------------------
   Keyed by (seq, at) rather than netwatch's (origin, seq, at): every
   ModelCallEvent comes from this one process, so there is no second origin for
   a bare seq comparison to be confused by, and neither field being the right
   type cannot throw building the key (String() never throws on a JSON value). */

function mcFresh(ev){
  var key = String(ev.seq) + ":" + String(ev.at);
  if (mcSeen[key]) return false;
  mcSeen[key] = 1;
  return true;
}

function mcIngest(ev){
  try {
    if (!ev || typeof ev !== "object") return;
    if (!mcFresh(ev)) return;
    mcRecordsList.push(ev);
    mcArrived = true;
    if (mcRecordsList.length > MAX_EVENTS) {
      mcRecordsList.splice(0, mcRecordsList.length - MAX_EVENTS);
      mcSeen = Object.create(null);
    }
    mcSchedulePaint();
  } catch (e) {
    // A hostile or merely malformed record must not break this feed, and must
    // not touch the netwatch feed running beside it.
  }
}

/* ---- stream ---------------------------------------------------------------
   Its own reconnect loop with its own local backoff, so a netwatch stall never
   pauses this one or vice versa — the only thing they share is the session
   token, which is correct: a session invalid for one feed is invalid for
   both, since it is the same bearer. */

async function mcReadStream(){
  var limit = mcEverConnected ? 400 : (launch.n ? Number(launch.n) : 400);
  if (!isFinite(limit) || limit < 0) limit = 400;
  var res = await fetch("/modelwatch?limit=" + limit + "&follow=1", {
    headers: { authorization: "Bearer " + token },
    cache: "no-store"
  });
  if (res.status === 401) {
    token = null;
    try { sessionStorage.removeItem(SESSION_KEY); } catch (e) {}
    throw new Error("unauthorized");
  }
  if (!res.ok || !res.body) throw new Error("HTTP " + res.status);

  mcClearFail();
  mcSetStatus("live", "streaming from the host");
  if (mcEverConnected) mcMark("reconnected");
  mcEverConnected = true;

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
        mcEvicted = (payload && typeof payload.evicted === "number") ? payload.evicted : 0;
        var buffered = (payload && typeof payload.buffered === "number") ? payload.buffered : 0;
        var replayed = (payload && typeof payload.replayed === "number") ? payload.replayed : 0;
        var missed = buffered - replayed;
        mcMark("live" + (missed > 0 ? "  ·  " + missed + " older buffered records not replayed" : ""));
        continue;
      }
      if (name === "shed") {
        var dropped = (payload && typeof payload.dropped === "number") ? payload.dropped : 0;
        mcShed += dropped;
        mcMark(dropped + " records dropped — this reader is behind the capture");
        continue;
      }
      mcIngest(payload);
    }
  }
}

async function mcRun(){
  var backoff = 400;
  for (;;) {
    try {
      await mcReadStream();
      backoff = 400;
      mcSetStatus("retry", "stream ended, reconnecting");
    } catch (e) {
      var why = e && e.message ? e.message : String(e);
      // Deliberately does NOT call showExpired(): that hides the whole page,
      // including a netwatch stream that may still be open and delivering
      // frames on its own still-valid connection. This feed's own credential
      // dying is this feed's own problem to report — see mcSetStatus for how
      // that reaches the tab even while the calls pane itself is hidden.
      if (!token) { mcSetStatus("dead", "unauthorized"); mcFail("session expired — reload the viewer for a fresh link"); return; }
      mcSetStatus("retry", why);
      mcFail("lost the host — retrying (" + clean(why, 80) + ")");
    }
    await new Promise(function(r){ setTimeout(r, backoff); });
    backoff = Math.min(backoff * 2, 5000);
  }
}

/* ---- arming -----------------------------------------------------------
   The viewer may arm ONLY the prompts arm — never context, and never both
   together. A 403 with code CONTEXT_ARM_FORBIDDEN can arrive for this
   prompts-only request whenever the CLI already holds the context arm up
   (arming prompts is what starts admitting transcript text once context is
   armed — see uiArmRefusal in control-listener.ts) — mcToggleArm below names
   that explicitly rather than leaving the button looking merely broken. */

function mcArmRequest(on){
  return { id:"ui-arm", type:"modelwatch:arm", arms:["prompts"], enabled:on, ttlMs: on ? ARM_TTL_MS : 0 };
}

async function mcPostArm(on, keepalive){
  var opts = {
    method: "POST",
    headers: { authorization: "Bearer " + token, "content-type": "application/json" },
    body: JSON.stringify(mcArmRequest(on))
  };
  if (keepalive) opts.keepalive = true;
  var res = await fetch("/netwatch/ui/arm", opts);
  var reply = null;
  try { reply = await res.json(); } catch (e) {}
  if (!res.ok || !reply || !reply.ok) {
    var msg = (reply && reply.error && typeof reply.error.message === "string") ? reply.error.message : "HTTP " + res.status;
    var e2 = new Error(msg);
    if (reply && reply.error && typeof reply.error.code === "string") e2.code = reply.error.code;
    throw e2;
  }
  return reply;
}

function mcSchedule(ttlMs){
  var a = mcArms.prompts;
  if (a.timer) clearTimeout(a.timer);
  a.timer = setTimeout(function(){
    // Spent the moment it fires — nothing later may find this id still
    // sitting in a.timer and think there is something left to clear.
    a.timer = null;
    if (!a.on) return; // disarmed while this renewal was in flight
    mcPostArm(true, false).then(function(reply){
      if (!a.on) return; // disarmed while the POST itself was in flight
      mcSchedule(reply.ttlMs);
    }, function(e){
      if (!a.on) return;
      // CONTEXT_ARM_FORBIDDEN means the CLI is holding the context arm up —
      // this page's own prompts grant from mcToggleArm has not lapsed, the
      // host's dead-man timer from that grant is still running. Disarming
      // here would blame the wrong arm, misreport an active capture as
      // stopped, and skip the pagehide purge (mcSetArm's disarm branch gates
      // on a.on). Keep the toggle lit and retry on the same cadence.
      if (e && e.code === "CONTEXT_ARM_FORBIDDEN") {
        mcFail("prompts renewal deferred — " + clean(e.message, 120));
        mcSchedule(ARM_TTL_MS);
        return;
      }
      mcSetArm(false);
      mcFail("prompts capture lapsed — " + clean(e.message, 80));
    });
  }, Math.max(1000, Math.floor((ttlMs || ARM_TTL_MS) * 0.4)));
}

/* Mirrors the host's own purge-on-disarm (forgetTextNoArmStillAdmits in
   modelwatch.ts): once THIS page's own arm goes down, holding onto text the
   host itself no longer admits — in the records list, in any export — would
   defeat the whole point of the arm being temporary. Metadata is left alone;
   only the fields the prompts arm alone gates are dropped. */
function mcForgetCapturedText(){
  for (var i = 0; i < mcRecordsList.length; i++) {
    var e = mcRecordsList[i];
    if (!e || typeof e !== "object") continue;
    if (e.prompt !== undefined) delete e.prompt;
    if (e.stdout !== undefined) delete e.stdout;
  }
}

function mcSetArm(on){
  var a = mcArms.prompts;
  a.on = on;
  if (!on && a.timer) { clearTimeout(a.timer); a.timer = null; }
  el("mcprompts").classList.toggle("on", on);
  if (on) {
    mcNoteEl.textContent = "prompts armed — scaffold, goal and a context digest are captured for " +
      "headless model calls from now, and stay in this window — and in any export — until " +
      "disarmed. " + MC_NOTE_BASE;
  } else {
    mcNoteEl.textContent = MC_NOTE_BASE;
    mcForgetCapturedText();
    // Without a repaint the purge is invisible until the next call arrives:
    // any row or open detail pane already on screen keeps showing text this
    // page just deleted.
    mcSchedulePaint();
  }
}

function mcToggleArm(){
  var btn = el("mcprompts");
  var want = !mcArms.prompts.on;
  btn.classList.add("busy");
  mcPostArm(want, false).then(function(reply){
    mcClearFail();
    mcSetArm(want);
    if (want) mcSchedule(reply.ttlMs);
  }, function(e){
    // CONTEXT_ARM_FORBIDDEN is a transient, externally-caused refusal (the CLI
    // is already holding the context arm up), not a permission the viewer
    // lacks — say so in words rather than leaving a dead-looking toggle.
    var msg = (e && e.code === "CONTEXT_ARM_FORBIDDEN")
      ? "prompts capture is unavailable right now — " + clean(e.message, 160)
      : "could not " + (want ? "arm " : "disarm ") + "prompts — " + clean(e && e.message, 120);
    mcFail(msg);
  }).then(function(){ btn.classList.remove("busy"); });
}

window.addEventListener("pagehide", function(){
  if (!token) return;
  if (mcArms.prompts.on) { try { mcPostArm(false, true); } catch (e) {} }
});

/* ---- export -------------------------------------------------------------
   Raw records, unfolded — one per phase, exactly as they arrived — the same
   choice cli/modelwatch.ts's --json mode makes and for the same reason:
   folding here would be this page deciding what a reader who exports sees. */

function mcExportJsonl(){
  var list = [];
  for (var i = 0; i < mcRecordsList.length; i++) { if (mcMatches(mcRecordsList[i])) list.push(mcRecordsList[i]); }
  if (!list.length) { mcFail("nothing to export under the current filter"); return; }
  var lines = [];
  for (var j = 0; j < list.length; j++) {
    try { lines.push(JSON.stringify(list[j])); } catch (e) {}
  }
  if (!lines.length) { mcFail("nothing to export under the current filter"); return; }
  var text = lines.join("\n") + "\n";
  var url = URL.createObjectURL(new Blob([text], { type: "application/x-ndjson" }));
  var d = new Date();
  var a = document.createElement("a");
  a.href = url;
  a.download = "modelcalls-" + d.getFullYear() + pad(d.getMonth()+1,2) + pad(d.getDate(),2) + "-" +
               pad(d.getHours(),2) + pad(d.getMinutes(),2) + pad(d.getSeconds(),2) + ".jsonl";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(function(){ URL.revokeObjectURL(url); }, 10000);
}

function mcClearAll(){
  mcRecordsList = [];
  mcSeen = Object.create(null);
  mcArrived = false;
  mcShed = 0;
  mcEvicted = 0;
  mcClearSelection();
  mcRebuild();
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

el("feedtabs").addEventListener("click", function(e){
  var b = e.target.closest ? e.target.closest("button") : null;
  if (!b) return;
  var f = b.getAttribute("data-f");
  Array.prototype.forEach.call(el("feedtabs").children, function(c){ c.classList.toggle("on", c === b); });
  nwPane.hidden = f !== "nw";
  mcPane.hidden = f !== "mc";
  // A hidden pane's [hidden] rule gives it no layout box, so any scrollTop
  // write made while it was hidden was a no-op against a 0/0/0 box. Restore
  // position now that the pane just regained a layout box — otherwise the
  // pane you switch TO opens on its oldest rows.
  if (f === "nw" && follow) scroll.scrollTop = scroll.scrollHeight;
  if (f === "mc" && mcFollow) mcScrollEl.scrollTop = mcScrollEl.scrollHeight;
});

el("mcpurpose").addEventListener("click", function(e){
  var b = e.target.closest ? e.target.closest("button") : null;
  if (!b) return;
  mcView.purpose = b.getAttribute("data-p");
  Array.prototype.forEach.call(el("mcpurpose").children, function(c){ c.classList.toggle("on", c === b); });
  mcRebuild();
});
var mcQTimer = null;
mcQEl.addEventListener("input", function(){
  if (mcQTimer) clearTimeout(mcQTimer);
  mcQTimer = setTimeout(function(){
    mcView.query = mcQEl.value.trim().toLowerCase();
    mcRebuild();
  }, 90);
});
el("mcpause").addEventListener("click", function(){
  mcView.paused = !mcView.paused;
  el("mcpause").classList.toggle("on", mcView.paused);
  if (!mcView.paused) mcRebuild();
});
el("mcprompts").addEventListener("click", mcToggleArm);
el("mcexp").addEventListener("click", mcExportJsonl);
el("mcclear").addEventListener("click", mcClearAll);

mcScrollEl.addEventListener("scroll", function(){
  mcFollow = mcAtBottom();
  if (mcFollow) mcJumpEl.hidden = true;
});
mcJumpEl.addEventListener("click", function(){
  mcFollow = true;
  mcJumpEl.hidden = true;
  mcScrollEl.scrollTop = mcScrollEl.scrollHeight;
});

document.addEventListener("keydown", function(e){
  var mcActive = !mcPane.hidden;
  var activeQ = mcActive ? mcQEl : q;
  var activePause = mcActive ? el("mcpause") : el("pause");
  var typing = e.target === q || e.target === mcQEl;
  if (e.key === "/" && !typing) { e.preventDefault(); activeQ.focus(); activeQ.select(); return; }
  if (e.key === "Escape") {
    if (typing) e.target.blur();
    else { clearSelection(); mcClearSelection(); }
    return;
  }
  if (e.key === " " && !typing) { e.preventDefault(); activePause.click(); }
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
  mcPaintCounts(0);
  run();
  mcRun();
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
