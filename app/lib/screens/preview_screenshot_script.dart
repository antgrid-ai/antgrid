/// Vanilla-JS (no framework deps, no vendored library) content script that
/// rasterizes the previewed page's current viewport into a PNG data URL and
/// posts it back through the `AntgridScreenshotCapture` JS channel — the
/// capture half of "Draw & Send", the annotate-a-screenshot flow that stands
/// in for [kElementPickerScript] where a DOM pick can't represent the
/// problem (a visual/layout glitch, not one specific node) and where a
/// touch device has no hover to preview a pick before committing.
///
/// There is no native screenshot API reachable from this webview package
/// (it renders through a platform view, not a Flutter `Texture`, so
/// `RenderRepaintBoundary.toImage()` cannot see it — see the module this was
/// designed alongside). Instead this walks the live DOM, clones it with every
/// element's *computed* style inlined (a detached clone has no cascade of
/// its own), wraps the clone in an SVG `<foreignObject>`, and lets the
/// browser's own SVG rasterizer paint that onto a `<canvas>`.
///
/// **An SVG image is rendered with no network access**, which is what makes
/// the naive version of this technique produce a page of broken-image icons
/// and fallback system fonts rather than a screenshot: every `<img>`,
/// `background-image`, and `@font-face` src has to already be a `data:` URL
/// by the time the SVG is handed to the rasterizer. So the bulk of this
/// script is the inlining pass — images (canvas-encoded when the pixels are
/// already decoded, fetched otherwise), CSS url() backgrounds, the
/// `@font-face` rules for families the page actually uses, and
/// `::before`/`::after` rules (re-emitted as real CSS against a generated
/// class, since a detached clone carries no pseudo-elements). It is
/// best-effort throughout and bounded by [_prepTimeoutMs] plus byte caps: a
/// resource that can't be inlined is left as-is rather than failing the
/// capture, which degrades to exactly what the un-inlined version produced.
///
/// The remaining known gaps: a cross-origin image with no CORS headers
/// (canvas-encoding taints, fetch is blocked) stays un-inlined; `<video>`
/// pixels and `<iframe>` content are not captured; an element scrolled
/// internally renders from its own top, since a static clone has no scroll
/// position to restore.
///
/// Only the current viewport is captured (not the full scrollable page) —
/// matching "screenshot what you're looking at", not a full-page stitch —
/// but at the page's own device pixel ratio (capped at [_maxScale]), so the
/// PNG the user draws on is as sharp as what they were looking at.
///
/// Posts either `{type:"error", message}` once, or a `{type:"start",
/// totalChunks}` followed by `totalChunks` `{type:"chunk", seq, data}`
/// messages and a final `{type:"end"}` — the PNG data URL chunked so no
/// single postMessage has to carry a multi-megabyte string (mirrors the
/// bridge's own chunked upload wire, `UploadService.kChunkBytes`).
const String kScreenshotCaptureScript = '''
(function() {
  // A fixed, curated property list rather than the full computed-style set
  // (300+ longhands) — cloning a page with thousands of nodes at full
  // fidelity would be slow enough to feel hung; this covers what actually
  // affects layout/paint for typical UI markup.
  var STYLE_PROPS = [
    'display','position','top','right','bottom','left','float','clear',
    'width','height','min-width','min-height','max-width','max-height',
    'margin-top','margin-right','margin-bottom','margin-left',
    'padding-top','padding-right','padding-bottom','padding-left',
    'box-sizing','border-top','border-right','border-bottom','border-left',
    'border-radius','outline','box-shadow','background','background-color',
    'background-image','background-position','background-size',
    'background-repeat','background-clip','-webkit-background-clip',
    '-webkit-text-fill-color','opacity','visibility','overflow','overflow-x',
    'overflow-y','z-index','color','font-family','font-size','font-weight',
    'font-style','font-variant','line-height','letter-spacing','word-spacing',
    'text-align','text-decoration','text-transform','text-overflow',
    'text-shadow','white-space','word-break','overflow-wrap','vertical-align',
    'list-style','flex','flex-direction','flex-wrap','justify-content',
    'align-items','align-content','align-self','flex-grow','flex-shrink',
    'flex-basis','order','gap','row-gap','column-gap','aspect-ratio',
    'grid-template-columns','grid-template-rows','grid-auto-flow',
    'grid-auto-rows','grid-column','grid-row','place-items','place-content',
    'border-collapse','border-spacing','table-layout','transform',
    'transform-origin','filter','mix-blend-mode','clip-path','object-fit',
    'object-position','stroke','stroke-width','fill','direction','cursor'
  ];

  // Ceilings on the inlining pass. Without them one page of full-bleed hero
  // photography turns a screenshot into a data URL large enough to stall the
  // chunked postMessage wire it has to travel back over.
  var MAX_IMAGE_BYTES = 12000000;
  var MAX_FONT_BYTES = 3000000;
  var MAX_FONT_FACES = 16;
  var PREP_TIMEOUT_MS = 8000;
  var MAX_SCALE = 2;
  // Above this element count the two extra getComputedStyle calls per node
  // that pseudo-element support costs stop being affordable — a page that
  // large is already near the point where the clone itself feels slow.
  var PSEUDO_NODE_BUDGET = 3000;

  var imageTasks = [];
  var bgTasks = [];
  var usedFamilies = {};
  var pseudoCss = '';
  var pseudoSeq = 0;
  var headClone = null;
  var imageBytes = 0;
  var fontBytes = 0;
  var urlCache = {};
  var scanPseudo =
    document.getElementsByTagName('*').length <= PSEUDO_NODE_BUDGET;

  function styleText(cs) {
    var css = '';
    for (var i = 0; i < STYLE_PROPS.length; i++) {
      var prop = STYLE_PROPS[i];
      var value = cs.getPropertyValue(prop);
      if (value) css += prop + ':' + value + ';';
    }
    return css;
  }

  // The FIRST family only: that is the one the page asked for and therefore
  // the one whose @font-face rules are worth inlining. The rest of the stack
  // is fallbacks the rasterizer resolves locally anyway.
  function noteFamily(cs) {
    var family = cs.getPropertyValue('font-family');
    if (!family) return;
    var first = family.split(',')[0].replace(/["']/g, '').trim().toLowerCase();
    if (first) usedFamilies[first] = true;
  }

  function serializeStyles(target, source) {
    var cs = getComputedStyle(source);
    target.setAttribute('style', styleText(cs));
    noteFamily(cs);
    var bg = cs.getPropertyValue('background-image');
    if (bg && bg.indexOf('url(') !== -1) {
      bgTasks.push({ el: target, value: bg });
    }
    if (scanPseudo) capturePseudo(target, source);
  }

  // A detached clone has no ::before/::after of its own, so each one that
  // renders content is re-emitted as a real rule against a generated class.
  function capturePseudo(target, source) {
    var which = ['::before', '::after'];
    for (var i = 0; i < which.length; i++) {
      var cs;
      try {
        cs = getComputedStyle(source, which[i]);
      } catch (e) {
        continue;
      }
      var content = cs.getPropertyValue('content');
      if (!content || content === 'none' || content === 'normal') continue;
      noteFamily(cs);
      var cls = 'ag-pseudo-' + (pseudoSeq++);
      var existing = target.getAttribute('class');
      target.setAttribute('class', existing ? existing + ' ' + cls : cls);
      var rule = styleText(cs) + 'content:' + content + ';';
      if (rule.indexOf('url(') !== -1) {
        bgTasks.push({ rule: cls + which[i], value: rule });
      }
      pseudoCss += '.' + cls + which[i] + '{' + rule + '}';
    }
  }

  function cloneWithStyles(node) {
    var clone = node.cloneNode(false);
    if (node.nodeType === 1) {
      var tag = node.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'LINK') {
        return document.createDocumentFragment();
      }
      serializeStyles(clone, node);
      if (tag === 'HEAD') headClone = clone;
      if (tag === 'IMG') {
        // srcset/sizes would have the rasterizer re-pick a candidate against
        // an SVG viewport that has no useful media context; pin the exact URL
        // the live page settled on and inline that one.
        clone.removeAttribute('srcset');
        clone.removeAttribute('sizes');
        clone.removeAttribute('loading');
        imageTasks.push({ el: clone, source: node });
      }
      if (tag === 'CANVAS') {
        try {
          var img = document.createElement('img');
          img.src = node.toDataURL();
          img.setAttribute('style', clone.getAttribute('style') || '');
          img.width = node.width;
          img.height = node.height;
          return img;
        } catch (e) {
          // Tainted source canvas — fall through to the empty placeholder
          // clone rather than failing the whole capture over one element.
        }
      }
      if (tag === 'INPUT' || tag === 'TEXTAREA') {
        clone.setAttribute('value', node.value == null ? '' : node.value);
      }
      if (tag === 'INPUT' && node.checked) {
        clone.setAttribute('checked', 'checked');
      }
    }
    var kids = node.childNodes;
    for (var j = 0; j < kids.length; j++) {
      var child = kids[j];
      if (child.nodeType === 1) {
        clone.appendChild(cloneWithStyles(child));
      } else if (child.nodeType === 3) {
        clone.appendChild(document.createTextNode(child.textContent));
      }
    }
    return clone;
  }

  function absolute(url, base) {
    try {
      return new URL(url, base || location.href).href;
    } catch (e) {
      return url;
    }
  }

  function blobToDataUrl(blob) {
    return new Promise(function(resolve) {
      try {
        var reader = new FileReader();
        reader.onload = function() { resolve(reader.result); };
        reader.onerror = function() { resolve(null); };
        reader.readAsDataURL(blob);
      } catch (e) {
        resolve(null);
      }
    });
  }

  // Fetch is the only path that works for a URL with no decoded element to
  // canvas-encode (backgrounds, fonts). Same-origin — which a dev server's
  // own assets always are — always succeeds; a CORS-less third-party asset
  // resolves null and stays un-inlined.
  function fetchDataUrl(url) {
    if (!url || url.indexOf('data:') === 0) return Promise.resolve(null);
    if (urlCache[url] !== undefined) return Promise.resolve(urlCache[url]);
    if (typeof fetch !== 'function') return Promise.resolve(null);
    var pending = fetch(url, { credentials: 'same-origin' })
      .then(function(res) { return res.ok ? res.blob() : null; })
      .then(function(blob) { return blob ? blobToDataUrl(blob) : null; })
      .catch(function() { return null; })
      .then(function(data) { urlCache[url] = data; return data; });
    urlCache[url] = pending;
    return pending;
  }

  var URL_RE = /url\\((['"]?)([^'")]+)\\1\\)/g;

  function rewriteUrls(value, base, budget) {
    var found = [];
    var match;
    URL_RE.lastIndex = 0;
    while ((match = URL_RE.exec(value)) !== null) found.push(match[2]);
    if (!found.length) return Promise.resolve(value);
    return Promise.all(
      found.map(function(u) { return fetchDataUrl(absolute(u, base)); })
    ).then(function(datas) {
      var i = 0;
      return value.replace(URL_RE, function(whole) {
        var data = datas[i++];
        if (!data) return whole;
        if (budget && !budget(data.length)) return whole;
        return 'url("' + data + '")';
      });
    });
  }

  function imageBudget(n) {
    if (imageBytes + n > MAX_IMAGE_BYTES) return false;
    imageBytes += n;
    return true;
  }

  function fontBudget(n) {
    if (fontBytes + n > MAX_FONT_BYTES) return false;
    fontBytes += n;
    return true;
  }

  // Canvas-encoding first: the pixels are already decoded in the live page,
  // so this needs no network and works while offline. It throws only on a
  // cross-origin image without CORS headers (tainted canvas), where fetch is
  // the fallback — and where fetch will usually be blocked too.
  function encodeLoadedImage(el, url) {
    if (!el.complete || !el.naturalWidth) return null;
    try {
      var canvas = document.createElement('canvas');
      canvas.width = el.naturalWidth;
      canvas.height = el.naturalHeight;
      canvas.getContext('2d').drawImage(el, 0, 0);
      // Re-encoding a photograph as PNG can be an order of magnitude larger
      // than the bytes the page actually downloaded, and every one of them
      // has to travel back over the chunked postMessage wire. Anything the
      // page itself served as JPEG cannot have had transparency to lose.
      var path = (url || '').split('?')[0].split('#')[0].toLowerCase();
      var isJpeg = path.slice(-4) === '.jpg' || path.slice(-5) === '.jpeg';
      return isJpeg
        ? canvas.toDataURL('image/jpeg', 0.9)
        : canvas.toDataURL('image/png');
    } catch (e) {
      return null;
    }
  }

  function inlineImages() {
    return Promise.all(imageTasks.map(function(task) {
      var url = task.source.currentSrc || task.source.src || '';
      if (!url || url.indexOf('data:') === 0) return Promise.resolve();
      var encoded = encodeLoadedImage(task.source, url);
      if (encoded && imageBudget(encoded.length)) {
        task.el.setAttribute('src', encoded);
        return Promise.resolve();
      }
      return fetchDataUrl(url).then(function(data) {
        if (data && imageBudget(data.length)) task.el.setAttribute('src', data);
      });
    }));
  }

  function inlineBackgrounds() {
    return Promise.all(bgTasks.map(function(task) {
      return rewriteUrls(task.value, location.href, imageBudget)
        .then(function(rewritten) {
          if (rewritten === task.value) return;
          if (task.el) {
            var style = task.el.getAttribute('style') || '';
            task.el.setAttribute(
              'style',
              style + 'background-image:' + rewritten + ';'
            );
          } else {
            pseudoCss += '.' + task.rule + '{' + rewritten + '}';
          }
        });
    }));
  }

  // Only the first source in each src list, preferring woff2: the rest are
  // format fallbacks the rasterizer would never reach, and each one inlined
  // is another whole font file base64'd into the SVG.
  function trimFontSrc(text) {
    return text.replace(/src\\s*:([^;}]+)/i, function(whole, list) {
      var parts = list.split(/,(?![^(]*\\))/);
      var pick = null;
      for (var i = 0; i < parts.length; i++) {
        if (/woff2/i.test(parts[i])) { pick = parts[i]; break; }
      }
      if (!pick) {
        for (var j = 0; j < parts.length; j++) {
          if (/url\\(/.test(parts[j])) { pick = parts[j]; break; }
        }
      }
      return pick ? 'src:' + pick : whole;
    });
  }

  function faceFamily(text) {
    var m = /font-family\\s*:\\s*([^;}]+)/i.exec(text);
    if (!m) return '';
    return m[1].replace(/["']/g, '').trim().toLowerCase();
  }

  function collectFontFaces() {
    var faces = [];
    var pending = [];
    var sheets = document.styleSheets;
    for (var i = 0; i < sheets.length; i++) {
      var sheet = sheets[i];
      var rules = null;
      try {
        rules = sheet.cssRules;
      } catch (e) {
        rules = null;
      }
      if (rules) {
        for (var j = 0; j < rules.length; j++) {
          // 5 === CSSRule.FONT_FACE_RULE, spelled numerically because the
          // constant is missing on some webview engines.
          if (rules[j].type === 5) {
            faces.push({ text: rules[j].cssText, base: sheet.href });
          }
        }
        continue;
      }
      // A cross-origin stylesheet (a font CDN, typically) refuses cssRules
      // but still serves its text over CORS — that is the whole reason a
      // web font renders on the page yet vanishes from the capture.
      if (sheet.href) {
        pending.push(
          (function(href) {
            return fetch(href)
              .then(function(res) { return res.ok ? res.text() : ''; })
              .then(function(text) {
                var re = /@font-face\\s*\\{[^}]*\\}/g;
                var m;
                while ((m = re.exec(text)) !== null) {
                  faces.push({ text: m[0], base: href });
                }
              })
              .catch(function() {});
          })(sheet.href)
        );
      }
    }
    return Promise.all(pending).then(function() { return faces; });
  }

  function inlineFonts() {
    if (typeof fetch !== 'function') return Promise.resolve('');
    return collectFontFaces().then(function(faces) {
      var wanted = [];
      for (var i = 0; i < faces.length && wanted.length < MAX_FONT_FACES; i++) {
        if (usedFamilies[faceFamily(faces[i].text)]) wanted.push(faces[i]);
      }
      return Promise.all(
        wanted.map(function(face) {
          return rewriteUrls(trimFontSrc(face.text), face.base, fontBudget)
            .catch(function() { return ''; });
        })
      ).then(function(rules) {
        // Only a face that actually carries its bytes inline is worth
        // emitting; one still pointing at a URL would just fail to load
        // inside the SVG and shadow the local fallback.
        return rules.filter(function(r) {
          return r && r.indexOf('url("data:') !== -1;
        }).join('');
      });
    });
  }

  function sendError(message) {
    if (window.AntgridScreenshotCapture) {
      window.AntgridScreenshotCapture.postMessage(
        JSON.stringify({type: 'error', message: message})
      );
    }
  }

  function sendChunks(dataUrl) {
    var chan = window.AntgridScreenshotCapture;
    if (!chan) return;
    var CHUNK = 200000;
    var total = Math.max(1, Math.ceil(dataUrl.length / CHUNK));
    chan.postMessage(JSON.stringify({type: 'start', totalChunks: total}));
    for (var i = 0; i < total; i++) {
      var part = dataUrl.slice(i * CHUNK, (i + 1) * CHUNK);
      chan.postMessage(JSON.stringify({type: 'chunk', seq: i, data: part}));
    }
    chan.postMessage(JSON.stringify({type: 'end'}));
  }

  // A blob URL avoids encodeURIComponent-ing a multi-megabyte SVG string,
  // which with every asset inlined is the common case rather than the
  // pathological one. Any engine that refuses to rasterize one (or taints
  // the canvas for it) falls back to the data URL on the retry.
  function rasterize(svgStr, w, h, scale, useBlob) {
    var objectUrl = null;
    var src;
    if (useBlob) {
      try {
        objectUrl = URL.createObjectURL(
          new Blob([svgStr], {type: 'image/svg+xml;charset=utf-8'})
        );
        src = objectUrl;
      } catch (e) {
        useBlob = false;
      }
    }
    if (!useBlob) {
      src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svgStr);
    }

    function release() {
      if (objectUrl) {
        URL.revokeObjectURL(objectUrl);
        objectUrl = null;
      }
    }

    var img = new Image();
    img.onload = function() {
      var png;
      try {
        var canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(w * scale));
        canvas.height = Math.max(1, Math.round(h * scale));
        var ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
        png = canvas.toDataURL('image/png');
      } catch (e) {
        release();
        if (useBlob) { rasterize(svgStr, w, h, scale, false); return; }
        sendError('render-failed: ' + (e && e.message ? e.message : String(e)));
        return;
      }
      release();
      sendChunks(png);
    };
    img.onerror = function() {
      release();
      if (useBlob) { rasterize(svgStr, w, h, scale, false); return; }
      sendError('image-load-failed');
    };
    img.src = src;
  }

  function withTimeout(promise, ms) {
    return Promise.race([
      promise,
      new Promise(function(resolve) { setTimeout(resolve, ms); })
    ]);
  }

  try {
    var w = window.innerWidth;
    var h = window.innerHeight;
    var scrollY = window.scrollY || 0;
    var scale = Math.min(window.devicePixelRatio || 1, MAX_SCALE);

    var root = document.documentElement;
    var clone = cloneWithStyles(root);

    var svgNS = 'http://www.w3.org/2000/svg';
    var xhtmlNS = 'http://www.w3.org/1999/xhtml';
    clone.setAttribute('xmlns', xhtmlNS);

    var prep = Promise.all([
      inlineImages(),
      inlineBackgrounds(),
      inlineFonts()
    ]).then(function(results) { return results[2]; });

    var finished = false;
    var finish = function(fontCss) {
      if (finished) return;
      finished = true;
      try {
        var css = (typeof fontCss === 'string' ? fontCss : '') + pseudoCss;
        if (css) {
          var styleEl = document.createElement('style');
          styleEl.appendChild(document.createTextNode(css));
          (headClone || clone).appendChild(styleEl);
        }

        var svg = document.createElementNS(svgNS, 'svg');
        svg.setAttribute('xmlns', svgNS);
        // Rendered at the device pixel ratio but laid out in CSS pixels: the
        // viewBox is what makes the rasterizer paint text and vectors at the
        // larger size instead of upscaling a viewport-sized bitmap.
        svg.setAttribute('width', String(Math.round(w * scale)));
        svg.setAttribute('height', String(Math.round(h * scale)));
        svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
        var fo = document.createElementNS(svgNS, 'foreignObject');
        fo.setAttribute('x', '0');
        fo.setAttribute('y', String(-scrollY));
        fo.setAttribute('width', String(w));
        fo.setAttribute('height', String(root.scrollHeight || h));
        fo.appendChild(clone);
        svg.appendChild(fo);

        var svgStr = new XMLSerializer().serializeToString(svg);
        rasterize(svgStr, w, h, scale, true);
      } catch (e) {
        sendError('capture-failed: ' + (e && e.message ? e.message : String(e)));
      }
    };

    withTimeout(prep, PREP_TIMEOUT_MS).then(finish, function() { finish(''); });
  } catch (e) {
    sendError('capture-failed: ' + (e && e.message ? e.message : String(e)));
  }
})();
''';
