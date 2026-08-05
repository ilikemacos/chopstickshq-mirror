/**
 * List GitHub release files at the bottom of product pages.
 *
 * Usage:
 *   <div id="github-files"
 *        data-repo="ilikemacos/rNitro"
 *        data-cdn-base="/rnitro/"
 *        data-title="All release files"></div>
 *   <script src="/js/github-files.js"></script>
 *
 * Fetches public releases from api.github.com and renders download links.
 * When a same-named file exists on this CDN (HEAD ok), also links the CDN copy.
 */
(function () {
  var root = document.getElementById('github-files');
  if (!root) return;

  var repo = root.getAttribute('data-repo') || '';
  var cdnBase = (root.getAttribute('data-cdn-base') || './').replace(/\/?$/, '/');
  var title = root.getAttribute('data-title') || 'All release files';
  var maxReleases = parseInt(root.getAttribute('data-max-releases') || '15', 10);

  root.innerHTML =
    '<div class="gh-files-inner">' +
    '<div class="gh-files-head">' +
    '<div class="gh-files-kicker">GitHub</div>' +
    '<h2 class="gh-files-title">' + escapeHtml(title) + '</h2>' +
    '<p class="gh-files-lead">Every asset from ' +
    '<a href="https://github.com/' + encodeURI(repo) + '/releases" rel="noopener" target="_blank">' +
    escapeHtml(repo) +
    ' releases</a>. Prefer the current download above; older files stay listed for archives.</p>' +
    '</div>' +
    '<div class="gh-files-status" id="gh-files-status">Loading release files…</div>' +
    '<div class="gh-files-list" id="gh-files-list" hidden></div>' +
    '</div>';

  var statusEl = document.getElementById('gh-files-status');
  var listEl = document.getElementById('gh-files-list');

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function fmtSize(n) {
    if (n == null || isNaN(n)) return '—';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function fmtDate(iso) {
    if (!iso) return '';
    try {
      var d = new Date(iso);
      return d.toISOString().slice(0, 10);
    } catch (e) {
      return '';
    }
  }

  function extOf(name) {
    var m = String(name).match(/\.([a-z0-9]+)$/i);
    return m ? m[1].toLowerCase() : '';
  }

  function typeLabel(name) {
    var e = extOf(name);
    if (e === 'zip') return 'App ZIP';
    if (e === 'dmg') return 'DMG';
    if (e === 'pkg') return 'PKG';
    if (e === 'sh') return 'Shell';
    if (e === 'ps1') return 'PowerShell';
    if (e === 'exe') return 'Windows';
    if (e === 'gz' || e === 'tgz') return 'Tarball';
    if (e === 'json') return 'JSON';
    return e ? e.toUpperCase() : 'File';
  }

  function cdnUrl(name) {
    return cdnBase + encodeURIComponent(name).replace(/%2F/g, '/');
  }

  // HEAD check with short timeout — optional CDN mirror badge
  function probeCdn(name) {
    return fetch(cdnUrl(name), { method: 'HEAD', cache: 'no-store' })
      .then(function (r) {
        return r.ok;
      })
      .catch(function () {
        return false;
      });
  }

  fetch('https://api.github.com/repos/' + repo + '/releases?per_page=' + maxReleases, {
    headers: { Accept: 'application/vnd.github+json' },
  })
    .then(function (r) {
      if (!r.ok) throw new Error('GitHub API ' + r.status);
      return r.json();
    })
    .then(function (releases) {
      if (!Array.isArray(releases) || !releases.length) {
        statusEl.textContent = 'No public releases found on GitHub.';
        return;
      }

      var html = '';
      var probes = [];

      releases.forEach(function (rel, ri) {
        var assets = rel.assets || [];
        if (!assets.length) return;
        var tag = rel.tag_name || rel.name || 'release';
        var date = fmtDate(rel.published_at || rel.created_at);
        html +=
          '<details class="gh-release"' +
          (ri === 0 ? ' open' : '') +
          '>' +
          '<summary class="gh-release-sum">' +
          '<span class="gh-tag">' +
          escapeHtml(tag) +
          '</span>' +
          (date ? '<span class="gh-date">' + date + '</span>' : '') +
          '<span class="gh-count">' +
          assets.length +
          ' file' +
          (assets.length === 1 ? '' : 's') +
          '</span>' +
          '</summary>' +
          '<ul class="gh-asset-list">';

        assets.forEach(function (a, ai) {
          var id = 'gh-cdn-' + ri + '-' + ai;
          var gh = a.browser_download_url || a.url;
          html +=
            '<li class="gh-asset">' +
            '<div class="gh-asset-meta">' +
            '<span class="gh-type">' +
            escapeHtml(typeLabel(a.name)) +
            '</span>' +
            '<code class="gh-name">' +
            escapeHtml(a.name) +
            '</code>' +
            '<span class="gh-size">' +
            fmtSize(a.size) +
            '</span>' +
            '</div>' +
            '<div class="gh-asset-actions">' +
            '<a class="gh-link" href="' +
            escapeHtml(gh) +
            '" rel="noopener" download>GitHub</a>' +
            '<a class="gh-link gh-cdn" id="' +
            id +
            '" hidden href="' +
            escapeHtml(cdnUrl(a.name)) +
            '" download>CDN</a>' +
            '</div>' +
            '</li>';
          probes.push(
            probeCdn(a.name).then(function (ok) {
              if (!ok) return;
              var el = document.getElementById(id);
              if (el) el.hidden = false;
            })
          );
        });

        html += '</ul></details>';
      });

      if (!html) {
        statusEl.textContent = 'Releases found, but no downloadable assets.';
        return;
      }

      statusEl.hidden = true;
      listEl.hidden = false;
      listEl.innerHTML = html;
      Promise.all(probes).catch(function () {});
    })
    .catch(function (err) {
      statusEl.innerHTML =
        'Could not load GitHub releases (' +
        escapeHtml(err && err.message ? err.message : 'error') +
        '). ' +
        '<a href="https://github.com/' +
        encodeURI(repo) +
        '/releases" rel="noopener" target="_blank">Open releases on GitHub →</a>';
    });
})();
