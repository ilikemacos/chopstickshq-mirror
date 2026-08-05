/**
 * Chopsticks HQ theme: dark | light
 * Key: chq.theme  — missing = follow prefers-color-scheme, then dark.
 */
(function () {
  var KEY = 'chq.theme';

  function systemPrefersLight() {
    try {
      return window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches;
    } catch (e) {
      return false;
    }
  }

  function resolve(stored) {
    if (stored === 'light' || stored === 'dark') return stored;
    return systemPrefersLight() ? 'light' : 'dark';
  }

  function apply(theme) {
    var t = theme === 'light' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', t);
    try {
      document.documentElement.style.colorScheme = t;
    } catch (e) {}
    var btns = document.querySelectorAll('[data-theme-toggle]');
    for (var i = 0; i < btns.length; i++) {
      var b = btns[i];
      b.setAttribute('aria-label', t === 'light' ? 'Switch to dark theme' : 'Switch to light theme');
      b.setAttribute('title', t === 'light' ? 'Dark mode' : 'Light mode');
      var label = b.querySelector('[data-theme-label]');
      if (label) label.textContent = t === 'light' ? 'Dark' : 'Light';
    }
  }

  function stored() {
    try {
      return localStorage.getItem(KEY);
    } catch (e) {
      return null;
    }
  }

  function save(theme) {
    try {
      localStorage.setItem(KEY, theme);
    } catch (e) {}
  }

  function init() {
    apply(resolve(stored()));
    document.addEventListener('click', function (e) {
      var t = e.target.closest && e.target.closest('[data-theme-toggle]');
      if (!t) return;
      e.preventDefault();
      var cur = document.documentElement.getAttribute('data-theme') || 'dark';
      var next = cur === 'light' ? 'dark' : 'light';
      save(next);
      apply(next);
    });
  }

  // Early paint: set before body if possible
  apply(resolve(stored()));

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  // Follow OS only when user has no saved preference
  try {
    if (window.matchMedia) {
      window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', function () {
        if (!stored()) apply(resolve(null));
      });
    }
  } catch (e) {}
})();
