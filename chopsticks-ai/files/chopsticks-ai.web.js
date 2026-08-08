/**
 * chopsticksAI - the Chopsticks HQ assistant.
 *
 * Answers entirely in the browser from window.CHOPSTICKS_AI_KB. No network
 * requests, no API keys, nothing leaves the page. The retrieval engine here
 * mirrors the Swift one shipped inside rNitro; both must score identically.
 */
(function () {
  'use strict';

  if (window.__CHOPSTICKS_AI__) return;
  window.__CHOPSTICKS_AI__ = true;

  var KB = window.CHOPSTICKS_AI_KB;
  if (!KB || !KB.intents || !KB.intents.length) return;

  // ---------------------------------------------------------------- engine ---

  function normalise(text) {
    return String(text)
      .toLowerCase()
      .replace(/[^a-z0-9\s]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /**
   * Word-boundary containment. Plain substring matching is what makes the
   * older bots answer "unzip the file" with the ZIP download, so a term only
   * counts when it sits on whole-word boundaries.
   */
  function containsTerm(haystackPadded, term) {
    return haystackPadded.indexOf(' ' + term + ' ') !== -1;
  }

  function score(query) {
    var text = normalise(query);
    if (!text) return [];
    var padded = ' ' + text + ' ';

    var results = [];
    for (var i = 0; i < KB.intents.length; i++) {
      var intent = KB.intents[i];
      var total = 0;
      var hits = 0;
      for (var j = 0; j < intent.terms.length; j++) {
        var term = intent.terms[j][0];
        var weight = intent.terms[j][1];
        if (containsTerm(padded, term)) {
          total += weight;
          hits++;
        }
      }
      if (total > 0) {
        results.push({ intent: intent, score: total, hits: hits });
      }
    }

    // Deterministic ordering: score, then authored priority, then id. Never
    // array order, which is what made the old KB's duplicate keywords resolve
    // by accident.
    results.sort(function (a, b) {
      if (b.score !== a.score) return b.score - a.score;
      if (b.intent.priority !== a.intent.priority) {
        return b.intent.priority - a.intent.priority;
      }
      return a.intent.id < b.intent.id ? -1 : 1;
    });
    return results;
  }

  var CONFIDENCE_FLOOR = 4;

  function ask(query) {
    var ranked = score(query);
    if (!ranked.length || ranked[0].score < CONFIDENCE_FLOOR) {
      return {
        answer:
          "I'm not sure about that one.\n\nI know about rNitro, Fathom Air, " +
          'Fathom Pro, ARENA, installing, and privacy. Try rephrasing, or pick ' +
          'one of these:',
        confident: false,
        suggestions: ranked.slice(0, 3).map(function (r) { return r.intent; })
      };
    }
    return {
      answer: ranked[0].intent.answer,
      confident: true,
      intent: ranked[0].intent,
      suggestions: ranked.slice(1, 4).map(function (r) { return r.intent; })
    };
  }

  window.chopsticksAI = { ask: ask, score: score, normalise: normalise, kb: KB };

  // ------------------------------------------------------------------ model ---
  // chopsticksAI answers through a real model. The API key lives as a server
  // secret behind /api/chopsticks-ai - it is never shipped to the browser.
  // The offline KB above stays as the fallback for when that endpoint is
  // unreachable, so the assistant degrades instead of dying.

  var HOSTS = ['', 'https://chopstickshq.com'];
  var history = [];

  function endpointsFor(path) {
    return HOSTS.filter(function (base) {
      // github.io has no serverless functions; skip straight to the real host.
      return !(base === '' && location.hostname.endsWith('github.io'));
    }).map(function (base) { return base + path; });
  }

  function askModel(text) {
    var sr = parseSearch(text);
    history.push({ role: 'user', content: sr.raw });
    var urls = endpointsFor('/api/chopsticks-ai');
    var i = 0;
    var payload = { messages: history.slice(-12) };
    if (sr.hadPrefix && payload.messages.length) {
      payload.messages = payload.messages.slice();
      payload.messages[payload.messages.length - 1] = { role: 'user', content: sr.query };
    }

    function attempt() {
      if (i >= urls.length) return Promise.reject(new Error('unreachable'));
      var url = urls[i++];
      return fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          if (!d || !d.reply) throw new Error('empty');
          return d;
        })
        .catch(attempt);
    }

    return attempt().then(function (d) {
      history.push({ role: 'assistant', content: d.reply });
      return d;
    });
  }

  window.chopsticksAI.askModel = askModel;
  window.chopsticksAI.resetHistory = function () { history = []; };

  // ---------------------------------------------------------------- widget ---

  var STARTERS = [
    'What is chopsticksAI?',
    'How do I install rNitro?',
    'macOS says it can’t be opened',
    'How do I unlock Fathom Pro?',
    'Explain how SSDs work',
    'Write me a haiku about Mondays'
  ];

  var CSS =
    '.cai-launcher{position:fixed;bottom:22px;left:22px;z-index:9998;width:52px;height:52px;' +
    'border-radius:50%;border:1px solid var(--border,#26262e);background:var(--card,#121216);' +
    'color:var(--text,#f2f2f5);font-size:20px;cursor:pointer;display:flex;align-items:center;' +
    'justify-content:center;box-shadow:0 4px 24px -4px rgba(0,0,0,.45);transition:transform .15s}' +
    '.cai-launcher:hover{transform:translateY(-2px)}' +
    '.cai-panel{position:fixed;bottom:86px;left:22px;z-index:9998;width:min(380px,calc(100vw - 44px));' +
    'max-height:min(560px,calc(100vh - 130px));background:var(--card,#121216);' +
    'border:1px solid var(--border,#26262e);border-radius:14px;display:none;flex-direction:column;' +
    'overflow:hidden;box-shadow:0 12px 40px rgba(0,0,0,.5);font-family:var(--sans,Inter,system-ui,sans-serif)}' +
    '.cai-panel.open{display:flex}' +
    '.cai-head{padding:14px 16px;border-bottom:1px solid var(--border,#26262e);background:var(--bg2,#0e0e12)}' +
    '.cai-title{font-family:var(--display,"Space Grotesk",system-ui,sans-serif);font-weight:600;' +
    'font-size:15px;color:var(--text,#f2f2f5);letter-spacing:-.01em}' +
    '.cai-sub{font-family:var(--mono,"JetBrains Mono",monospace);font-size:10px;letter-spacing:.14em;' +
    'text-transform:uppercase;color:var(--muted,#8b8b9a);margin-top:3px}' +
    '.cai-log{flex:1;overflow-y:auto;padding:14px 16px;display:flex;flex-direction:column;gap:10px}' +
    '.cai-msg{max-width:88%;padding:9px 12px;border-radius:11px;font-size:13.5px;line-height:1.55;white-space:pre-wrap}' +
    '.cai-bot{align-self:flex-start;background:var(--bg2,#0e0e12);border:1px solid var(--border,#26262e);' +
    'color:var(--text,#f2f2f5)}' +
    '.cai-user{align-self:flex-end;background:var(--text,#f2f2f5);color:var(--bg,#0a0a0c)}' +
    '.cai-chips{display:flex;flex-wrap:wrap;gap:6px;padding:0 16px 12px}' +
    '.cai-chip{background:transparent;border:1px solid var(--border,#26262e);color:var(--muted,#8b8b9a);' +
    'border-radius:999px;padding:6px 11px;font-size:11.5px;cursor:pointer;font-family:inherit;text-align:left}' +
    '.cai-chip:hover{color:var(--text,#f2f2f5);border-color:var(--muted,#8b8b9a)}' +
    '.cai-form{display:flex;gap:8px;padding:12px 14px;border-top:1px solid var(--border,#26262e)}' +
    '.cai-input{flex:1;background:var(--bg,#0a0a0c);border:1px solid var(--border,#26262e);border-radius:9px;' +
    'padding:9px 11px;color:var(--text,#f2f2f5);font-size:13px;font-family:inherit;min-width:0}' +
    '.cai-input:focus{outline:none;border-color:var(--muted,#8b8b9a)}' +
    '.cai-send{background:var(--text,#f2f2f5);color:var(--bg,#0a0a0c);border:none;border-radius:9px;' +
    'padding:0 14px;font-weight:600;font-size:13px;cursor:pointer;font-family:inherit}' +
    '.cai-usage{font-family:var(--mono,"JetBrains Mono",monospace);font-size:9px;letter-spacing:.06em;' +
    'color:var(--muted,#8b8b9a);margin-top:5px;line-height:1.45;text-align:right}' +
    '.cai-sources{margin-top:8px;padding-top:6px;border-top:1px solid rgba(255,255,255,.08)}' +
    '.cai-sources-label{font-family:var(--mono,"JetBrains Mono",monospace);font-size:9px;letter-spacing:.08em;' +
    'color:var(--muted,#8b8b9a);margin-bottom:4px;text-transform:uppercase}' +
    '.cai-source-link{display:block;font-size:11px;color:var(--text,#f2f2f5);opacity:.85;margin-top:3px;' +
    'text-decoration:underline;text-underline-offset:2px;word-break:break-word}' +
    '.cai-panel.compact{width:min(320px,calc(100vw - 32px));max-height:min(420px,calc(100vh - 110px))}' +
    '.cai-panel.compact .cai-head{padding:10px 12px}.cai-panel.compact .cai-title{font-size:13px}' +
    '.cai-panel.compact .cai-sub{font-size:9px}.cai-panel.compact .cai-msg{font-size:12px;padding:7px 10px}' +
    '.cai-panel.compact .cai-log{padding:10px 12px;gap:7px}.cai-panel.compact .cai-chips{display:none}' +
    '.cai-launcher.compact{width:44px;height:44px;font-size:17px;bottom:16px;left:16px}' +
    '@media (max-width:520px){.cai-panel{left:12px;bottom:78px}.cai-launcher{left:12px;bottom:14px}}';

  var panel, log, input, usageEl, started = false, compact = false;

  function fmt(n) {
    if (!isFinite(n)) return '?';
    if (n >= 1000000) return (n / 1000000).toFixed(1).replace(/\.0$/, '') + 'm';
    if (n >= 1000) return (n / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
    return String(Math.round(n));
  }

  try {
    compact = localStorage.getItem('chq.aiCompact') === '1';
  } catch (e) {}

  function setCompact(on) {
    compact = !!on;
    if (panel) panel.classList.toggle('compact', compact);
    var launcher = document.querySelector('.cai-launcher');
    if (launcher) launcher.classList.toggle('compact', compact);
    try { localStorage.setItem('chq.aiCompact', compact ? '1' : '0'); } catch (e) {}
  }

  function showUsage(d) {
    if (!usageEl) return;
    var parts = [];
    if (d && d.searched) parts.push('Web search');
    if (d && d.contextWindow && typeof d.contextWindow.used === 'number') {
      parts.push('Ctx ' + fmt(d.contextWindow.used) + '/' + fmt(d.contextWindow.limit));
    }
    if (d && d.budget && typeof d.budget.used === 'number') {
      parts.push('Allow ' + fmt(d.budget.used) + '/' + fmt(d.budget.limit));
    }
    usageEl.textContent = parts.join(' · ');
  }

  function parseSearch(text) {
    if (/^\/search\b/i.test(text)) {
      var q = text.replace(/^\/search\s*/i, '').trim();
      return { query: q || text, hadPrefix: true, raw: text };
    }
    return { query: text, hadPrefix: false, raw: text };
  }

  function appendSources(target, sources) {
    if (!sources || !sources.length) return;
    var wrap = el('div', 'cai-sources');
    wrap.appendChild(el('div', 'cai-sources-label', 'Sources'));
    sources.forEach(function (s) {
      if (s.url) {
        var a = document.createElement('a');
        a.className = 'cai-source-link';
        a.href = s.url;
        a.target = '_blank';
        a.rel = 'noopener noreferrer';
        a.textContent = s.title || s.url;
        wrap.appendChild(a);
      } else if (s.title) {
        wrap.appendChild(el('div', 'cai-source-link', s.title));
      }
    });
    target.appendChild(wrap);
  }

  function handleSlash(text) {
    var cmd = text.trim().toLowerCase();
    if (cmd === '/compact' || cmd === '/compact on') { setCompact(true); return true; }
    if (cmd === '/compact off') { setCompact(false); return true; }
    if (cmd === '/search') {
      addMsg('bot', 'Type `/search` followed by your question to force a web lookup.');
      return true;
    }
    return false;
  }

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function addMsg(who, text) {
    var m = el('div', 'cai-msg ' + (who === 'bot' ? 'cai-bot' : 'cai-user'), text);
    log.appendChild(m);
    log.scrollTop = log.scrollHeight;
    return m;
  }

  function showChips(items) {
    var old = panel.querySelector('.cai-chips');
    if (old) old.remove();
    if (!items || !items.length) return;
    var wrap = el('div', 'cai-chips');
    items.forEach(function (it) {
      var label = typeof it === 'string' ? it : it.label;
      var chip = el('button', 'cai-chip', label);
      chip.type = 'button';
      chip.addEventListener('click', function () { submit(label); });
      wrap.appendChild(chip);
    });
    panel.insertBefore(wrap, panel.querySelector('.cai-form'));
  }

  var busy = false;

  function kbFallback(text, target) {
    var res = ask(text);
    target.textContent = res.answer;
    if (res.suggestions && res.suggestions.length) showChips(res.suggestions);
  }

  function canKbFallback(text) {
    var ranked = score(text);
    return ranked.length && ranked[0].score >= CONFIDENCE_FLOOR;
  }

  function liveFailed(d) {
    return !d || !d.reply || (d.mode && d.mode !== 'live' && d.mode !== 'offline');
  }

  function submit(text) {
    text = (text || '').trim();
    if (!text || busy) return;
    if (handleSlash(text)) {
      input.value = '';
      addMsg('bot', compact ? 'Compact mode on.' : 'Compact mode off.');
      return;
    }
    addMsg('user', text);
    input.value = '';
    showChips(null);

    busy = true;
    var thinking = addMsg('bot', 'Thinking…');

    askModel(text)
      .then(function (d) {
        if (liveFailed(d) && canKbFallback(text)) {
          kbFallback(text, thinking);
        } else {
          thinking.textContent = '';
          thinking.appendChild(document.createTextNode(d && d.reply
            ? d.reply
            : "I couldn't reach the model just now — try again in a moment."));
          appendSources(thinking, d && d.sources);
          showUsage(d);
        }
      })
      .catch(function () {
        if (canKbFallback(text)) {
          kbFallback(text, thinking);
        } else {
          thinking.textContent =
            "I couldn't reach the model just now — try again in a moment.";
        }
      })
      .then(function () {
        busy = false;
        log.scrollTop = log.scrollHeight;
      });
  }

  function open() {
    panel.classList.add('open');
    if (!started) {
      started = true;
      addMsg('bot',
        "Hi, I'm ChopsticksAI.\n\n" +
        'Ask me anything — general questions, code, writing, or Chopsticks apps. ' +
        'Live answers go through chopstickshq.com (no account, no key from you). ' +
        'Offline fallback covers HQ product topics only. Tap a question below to start.');
      showChips(STARTERS);
    }
    input.focus();
  }

  function build() {
    var style = el('style');
    style.textContent = CSS;
    document.head.appendChild(style);

    var launcher = el('button', 'cai-launcher', '◉');
    launcher.type = 'button';
    launcher.setAttribute('aria-label', 'Open chopsticksAI');

    panel = el('div', 'cai-panel');
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-label', 'chopsticksAI');

    var head = el('div', 'cai-head');
    head.appendChild(el('div', 'cai-title', 'ChopsticksAI'));
    head.appendChild(el('div', 'cai-sub', 'Live proxy · offline KB · /compact'));
    usageEl = el('div', 'cai-usage');
    head.appendChild(usageEl);
    panel.appendChild(head);

    log = el('div', 'cai-log');
    panel.appendChild(log);

    var form = el('form', 'cai-form');
    input = el('input', 'cai-input');
    input.type = 'text';
    input.placeholder = 'Ask me anything…';
    input.setAttribute('aria-label', 'Ask chopsticksAI');
    var send = el('button', 'cai-send', 'Ask');
    send.type = 'submit';
    form.appendChild(input);
    form.appendChild(send);
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      submit(input.value);
    });
    panel.appendChild(form);

    launcher.addEventListener('click', function () {
      if (panel.classList.contains('open')) {
        panel.classList.remove('open');
        launcher.textContent = '◉';
      } else {
        open();
        launcher.textContent = '✕';
      }
    });

    document.body.appendChild(launcher);
    document.body.appendChild(panel);
    setCompact(compact);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', build);
  } else {
    build();
  }
})();
