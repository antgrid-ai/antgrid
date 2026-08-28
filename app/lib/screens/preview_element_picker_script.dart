/// Vanilla-JS (no framework deps) content script injected into the preview
/// webview on demand — arms hover-highlight + click-to-select + Escape-to-cancel
/// over whatever page is currently loaded. Framework-agnostic on purpose: the
/// previewed dev server can be any framework or none, so this can only work
/// off the DOM itself (tag/id/classes/text/outerHTML/selector) — there is no
/// source-file mapping the way a build-controlled previewer could offer.
///
/// Re-injected fresh each time the picker is armed (via `runJavaScript`), not
/// persisted across navigations — a real page load tears down the whole JS
/// world, taking any live listeners with it, so the picker naturally
/// disarms itself on navigation without extra cleanup.
///
/// Posts one message via the `AntgridElementPicker` JS channel:
/// `{type: "picked", tag, id, classes, text, html, selector, rect, viewport}`
/// on a click, or `{type: "cancelled"}` on Escape. `text`/`html` are capped so
/// a large subtree's markup can't blow up the chat message this eventually
/// becomes.
///
/// `rect` is the picked element's viewport-relative box and `viewport` the CSS
/// pixel size it was measured against. Together they are what lets the app crop
/// the same-moment screenshot down to the element the user actually pointed at
/// — attaching the whole page instead leaves the agent to guess which part of
/// it was meant, which is the one thing a pick already answered.
const String kElementPickerScript = '''
(function() {
  if (window.__antgridPickerActive) return;
  window.__antgridPickerActive = true;

  var TEXT_CAP = 200;
  var HTML_CAP = 500;

  var INTERACTIVE = {BUTTON:1, A:1, INPUT:1, SELECT:1, TEXTAREA:1, IMG:1, SVG:1, DIV:1};

  function isMeaningful(el) {
    if (!el || el.nodeType !== 1) return false;
    if (INTERACTIVE[el.tagName]) return true;
    var cs = getComputedStyle(el);
    if (cs.display === 'inline' || cs.display === 'contents') return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function nearestMeaningful(el) {
    var cur = el;
    while (cur && cur !== document.body) {
      if (isMeaningful(cur)) return cur;
      cur = cur.parentElement;
    }
    return el || document.body;
  }

  function xpathOf(el) {
    if (el.id) return '//*[@id="' + el.id + '"]';
    var parts = [];
    var cur = el;
    while (cur && cur.nodeType === 1 && cur !== document.body) {
      var idx = 1;
      var sib = cur.previousElementSibling;
      while (sib) {
        if (sib.tagName === cur.tagName) idx++;
        sib = sib.previousElementSibling;
      }
      parts.unshift(cur.tagName.toLowerCase() + '[' + idx + ']');
      cur = cur.parentElement;
    }
    return '//' + parts.join('/');
  }

  function cap(s, n) {
    if (!s) return '';
    return s.length > n ? s.slice(0, n) + '…' : s;
  }

  var overlay = document.createElement('div');
  overlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;'
    + 'border:2px solid #5e2ca5;background:rgba(94,44,165,0.12);display:none;'
    + 'transition:all 0.05s linear;';
  var label = document.createElement('div');
  label.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;'
    + 'background:#5e2ca5;color:#fff;padding:4px 8px;font:12px/1 monospace;'
    + 'border-radius:4px;white-space:nowrap;display:none;';
  document.documentElement.appendChild(overlay);
  document.documentElement.appendChild(label);

  function updateHighlight(el, x, y) {
    var r = el.getBoundingClientRect();
    overlay.style.display = 'block';
    overlay.style.left = r.left + 'px';
    overlay.style.top = r.top + 'px';
    overlay.style.width = r.width + 'px';
    overlay.style.height = r.height + 'px';

    label.textContent = el.id ? el.tagName.toLowerCase() + '#' + el.id : el.tagName.toLowerCase();
    label.style.display = 'block';
    var lx = x + 12 > window.innerWidth - 200 ? x - 200 : x + 12;
    var ly = y - 28 < 0 ? y + 16 : y - 28;
    label.style.left = lx + 'px';
    label.style.top = ly + 'px';
  }

  function onMouseMove(e) {
    updateHighlight(nearestMeaningful(e.target), e.clientX, e.clientY);
  }

  function onClick(e) {
    e.preventDefault();
    e.stopPropagation();
    var target = nearestMeaningful(e.target);
    // Measured BEFORE teardown: removing the overlay can reflow the page, and
    // the box has to describe the frame the screenshot will capture.
    var box = target.getBoundingClientRect();
    var payload = {
      type: 'picked',
      tag: target.tagName.toLowerCase(),
      id: target.id || null,
      classes: target.classList ? Array.prototype.slice.call(target.classList) : [],
      text: cap((target.textContent || '').trim(), TEXT_CAP),
      html: cap(target.outerHTML || '', HTML_CAP),
      selector: xpathOf(target),
      rect: {
        x: box.left,
        y: box.top,
        width: box.width,
        height: box.height
      },
      viewport: {width: window.innerWidth, height: window.innerHeight}
    };
    teardown();
    if (window.AntgridElementPicker) {
      window.AntgridElementPicker.postMessage(JSON.stringify(payload));
    }
  }

  function onKeyDown(e) {
    if (e.key === 'Escape') {
      teardown();
      if (window.AntgridElementPicker) {
        window.AntgridElementPicker.postMessage(JSON.stringify({type: 'cancelled'}));
      }
    }
  }

  function teardown() {
    window.__antgridPickerActive = false;
    document.removeEventListener('mousemove', onMouseMove, false);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('keydown', onKeyDown, false);
    overlay.remove();
    label.remove();
  }

  window.__antgridPickerStop = teardown;

  document.addEventListener('mousemove', onMouseMove, false);
  // Capture phase: must intercept the click before the page's own handlers
  // can navigate/submit/act on it.
  document.addEventListener('click', onClick, true);
  document.addEventListener('keydown', onKeyDown, false);
})();
''';

/// Teardown-only script for a Dart-triggered cancel (re-tapping an armed
/// toolbar button, or switching away from the tab the picker was armed on).
/// Safe to run even if the picker isn't currently active (optional chaining).
const String kElementPickerStopScript = 'window.__antgridPickerStop?.();';
