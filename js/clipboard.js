/**
 * Reliable clipboard helper for Chopsticks HQ install/terminal copy buttons.
 * Order: sync execCommand (keeps user-gesture on Safari) → async Clipboard API → selectable modal.
 */
(function (global) {
  'use strict';

  function tryExecCommandCopy(text) {
    try {
      var ta = document.createElement('textarea');
      ta.value = text;
      // iOS / Safari: must be in DOM, selectable, not display:none
      ta.setAttribute('readonly', '');
      ta.contentEditable = 'true';
      ta.style.cssText =
        'position:fixed;top:0;left:0;width:1px;height:1px;padding:0;margin:0;' +
        'border:0;outline:none;box-shadow:none;background:transparent;opacity:0.01;z-index:99999;';
      document.body.appendChild(ta);

      ta.focus();
      ta.select();
      ta.setSelectionRange(0, text.length);

      // Extra path for older WebKit
      try {
        var range = document.createRange();
        range.selectNodeContents(ta);
        var sel = window.getSelection();
        if (sel) {
          sel.removeAllRanges();
          sel.addRange(range);
        }
        ta.setSelectionRange(0, text.length);
      } catch (_) {}

      var ok = false;
      try {
        ok = document.execCommand('copy');
      } catch (_) {
        ok = false;
      }
      document.body.removeChild(ta);
      return !!ok;
    } catch (e) {
      return false;
    }
  }

  function showCopyModal(text, title) {
    var existing = document.getElementById('chq-copy-modal');
    if (existing) existing.remove();

    var wrap = document.createElement('div');
    wrap.id = 'chq-copy-modal';
    wrap.setAttribute('role', 'dialog');
    wrap.setAttribute('aria-modal', 'true');
    wrap.style.cssText =
      'position:fixed;inset:0;z-index:100000;display:flex;align-items:center;justify-content:center;' +
      'background:rgba(0,0,0,.72);padding:16px;font-family:system-ui,-apple-system,sans-serif;';

    var card = document.createElement('div');
    card.style.cssText =
      'width:min(560px,100%);background:#121216;color:#f2f2f5;border:1px solid #333;' +
      'border-radius:14px;padding:18px 18px 14px;box-shadow:0 20px 60px rgba(0,0,0,.5);';

    var h = document.createElement('div');
    h.textContent = title || 'Copy command';
    h.style.cssText = 'font-weight:600;font-size:15px;margin-bottom:8px;';

    var hint = document.createElement('div');
    hint.textContent = 'Press ⌘C / Ctrl+C to copy, then paste in Terminal.';
    hint.style.cssText = 'font-size:12px;color:#8b8b9a;margin-bottom:10px;';

    var ta = document.createElement('textarea');
    ta.value = text;
    ta.readOnly = true;
    ta.rows = Math.min(8, Math.max(3, text.split('\n').length + 1));
    ta.style.cssText =
      'width:100%;box-sizing:border-box;font-family:ui-monospace,Menlo,monospace;font-size:12px;' +
      'line-height:1.45;padding:12px;border-radius:10px;border:1px solid #333;background:#0a0a0c;color:#f2f2f5;' +
      'resize:vertical;outline:none;';

    var row = document.createElement('div');
    row.style.cssText = 'display:flex;gap:8px;justify-content:flex-end;margin-top:12px;';

    function btn(label, primary) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = label;
      b.style.cssText =
        'height:36px;padding:0 14px;border-radius:999px;border:1px solid ' +
        (primary ? 'transparent' : '#444') +
        ';background:' +
        (primary ? '#e8e8ed' : 'transparent') +
        ';color:' +
        (primary ? '#0a0a0c' : '#f2f2f5') +
        ';font-size:13px;font-weight:600;cursor:pointer;';
      return b;
    }

    var copyBtn = btn('Copy again', true);
    var closeBtn = btn('Close', false);

    function close() {
      wrap.remove();
      document.removeEventListener('keydown', onKey);
    }
    function onKey(e) {
      if (e.key === 'Escape') close();
    }
    document.addEventListener('keydown', onKey);

    copyBtn.addEventListener('click', function () {
      ta.focus();
      ta.select();
      ta.setSelectionRange(0, text.length);
      var ok = tryExecCommandCopy(text);
      if (ok) {
        copyBtn.textContent = 'Copied ✓';
        setTimeout(close, 600);
      } else if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(
          function () {
            copyBtn.textContent = 'Copied ✓';
            setTimeout(close, 600);
          },
          function () {
            copyBtn.textContent = 'Select text · ⌘C';
          }
        );
      } else {
        copyBtn.textContent = 'Select text · ⌘C';
      }
    });
    closeBtn.addEventListener('click', close);
    wrap.addEventListener('click', function (e) {
      if (e.target === wrap) close();
    });

    row.appendChild(closeBtn);
    row.appendChild(copyBtn);
    card.appendChild(h);
    card.appendChild(hint);
    card.appendChild(ta);
    card.appendChild(row);
    wrap.appendChild(card);
    document.body.appendChild(wrap);

    setTimeout(function () {
      ta.focus();
      ta.select();
      ta.setSelectionRange(0, text.length);
    }, 30);
  }

  /**
   * @param {string} text
   * @returns {Promise<boolean>}
   */
  function copyTextToClipboard(text) {
    if (text == null) return Promise.resolve(false);
    text = String(text);
    if (!text) return Promise.resolve(false);

    // 1) Sync path first — keeps user activation (critical after modal / Safari)
    if (tryExecCommandCopy(text)) {
      return Promise.resolve(true);
    }

    // 2) Async Clipboard API
    if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
      return navigator.clipboard
        .writeText(text)
        .then(function () {
          return true;
        })
        .catch(function () {
          return false;
        });
    }

    return Promise.resolve(false);
  }

  /**
   * Copy or open selectable modal. Always leaves the user with a way to copy.
   * @param {string} text
   * @param {{ successToast?: function(string), failTitle?: string, toastOk?: string }=} opts
   */
  function copyOrShow(text, opts) {
    opts = opts || {};
    return copyTextToClipboard(text).then(function (ok) {
      if (ok) {
        if (typeof opts.successToast === 'function') {
          opts.successToast(opts.toastOk || 'Copied to clipboard');
        }
        return true;
      }
      showCopyModal(text, opts.failTitle || 'Copy command');
      if (typeof opts.successToast === 'function') {
        opts.successToast('Select text and press ⌘C / Ctrl+C');
      }
      return false;
    });
  }

  // Click-to-copy for <pre data-copy> or .curl / .copyable
  function bindCopyableBlocks(root) {
    root = root || document;
    var nodes = root.querySelectorAll('pre.curl, pre.copyable, code.copyable, [data-copy]');
    nodes.forEach(function (el) {
      if (el.dataset.copyBound) return;
      el.dataset.copyBound = '1';
      el.style.cursor = 'pointer';
      if (!el.getAttribute('title')) el.setAttribute('title', 'Click to copy');
      el.addEventListener('click', function () {
        var text = el.getAttribute('data-copy') || el.textContent || '';
        text = text.replace(/\u00a0/g, ' ').trim();
        copyOrShow(text, {
          toastOk: 'Copied',
          failTitle: 'Copy',
          successToast: function (msg) {
            if (typeof global.toast === 'function') global.toast(msg);
          },
        });
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      bindCopyableBlocks();
    });
  } else {
    bindCopyableBlocks();
  }

  global.copyTextToClipboard = copyTextToClipboard;
  global.copyTextFallback = tryExecCommandCopy;
  global.copyOrShow = copyOrShow;
  global.showCopyModal = showCopyModal;
  global.bindCopyableBlocks = bindCopyableBlocks;
})(typeof window !== 'undefined' ? window : this);
