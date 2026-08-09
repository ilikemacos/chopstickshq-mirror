/**
 * ChopsticksAI cloud accounts + chat sync (Supabase Auth + PostgREST).
 * Optional — guests keep using localStorage only.
 */
(function (global) {
  'use strict';

  var CFG_URL = '/chopsticks-ai/supabase-public.json';
  var SESSION_KEY = 'chq.ai.auth';
  var cfg = null;
  var session = null;
  var listeners = [];

  function emit() {
    listeners.forEach(function (fn) {
      try { fn(session); } catch (e) {}
    });
  }

  function loadLocalSession() {
    try {
      var raw = localStorage.getItem(SESSION_KEY);
      if (!raw) return null;
      var s = JSON.parse(raw);
      if (!s || !s.access_token) return null;
      return s;
    } catch (e) { return null; }
  }

  function saveLocalSession(s) {
    try {
      if (s) localStorage.setItem(SESSION_KEY, JSON.stringify(s));
      else localStorage.removeItem(SESSION_KEY);
    } catch (e) {}
  }

  async function ensureConfig() {
    if (cfg) return cfg;
    var res = await fetch(CFG_URL, { cache: 'no-store' });
    if (!res.ok) throw new Error('Cloud config unavailable');
    cfg = await res.json();
    if (!cfg.url || !cfg.anonKey) throw new Error('Cloud config incomplete');
    return cfg;
  }

  async function authFetch(path, init) {
    var c = await ensureConfig();
    init = init || {};
    var headers = Object.assign({
      apikey: c.anonKey,
      'Content-Type': 'application/json'
    }, init.headers || {});
    if (session && session.access_token) {
      headers.Authorization = 'Bearer ' + session.access_token;
    } else {
      headers.Authorization = 'Bearer ' + c.anonKey;
    }
    var res = await fetch(c.url + path, Object.assign({}, init, { headers: headers }));
    var text = await res.text();
    var body = null;
    try { body = text ? JSON.parse(text) : null; } catch (e) { body = text; }
    if (!res.ok) {
      var msg = (body && (body.error_description || body.msg || body.message || body.error)) || ('HTTP ' + res.status);
      var err = new Error(typeof msg === 'string' ? msg : JSON.stringify(msg));
      err.status = res.status;
      err.body = body;
      throw err;
    }
    return body;
  }

  async function rest(path, init) {
    return authFetch('/rest/v1/' + path, init);
  }

  async function refreshIfNeeded() {
    if (!session || !session.refresh_token) return session;
    var exp = session.expires_at ? session.expires_at * 1000 : 0;
    if (exp && Date.now() < exp - 60000) return session;
    try {
      var body = await authFetch('/auth/v1/token?grant_type=refresh_token', {
        method: 'POST',
        body: JSON.stringify({ refresh_token: session.refresh_token })
      });
      session = normalizeSession(body);
      saveLocalSession(session);
      emit();
      return session;
    } catch (e) {
      session = null;
      saveLocalSession(null);
      emit();
      return null;
    }
  }

  function normalizeSession(body) {
    if (!body || !body.access_token) return null;
    return {
      access_token: body.access_token,
      refresh_token: body.refresh_token,
      expires_at: body.expires_at || (Math.floor(Date.now() / 1000) + (body.expires_in || 3600)),
      user: body.user || null
    };
  }

  var Cloud = {
    onChange: function (fn) {
      listeners.push(fn);
      return function () {
        listeners = listeners.filter(function (x) { return x !== fn; });
      };
    },
    getSession: function () { return session; },
    userEmail: function () {
      return (session && session.user && session.user.email) || '';
    },
    isSignedIn: function () { return Boolean(session && session.access_token); },

    init: async function () {
      await ensureConfig();
      session = loadLocalSession();
      if (session) {
        try {
          await refreshIfNeeded();
          var user = await authFetch('/auth/v1/user', { method: 'GET' });
          if (user) {
            session.user = user;
            saveLocalSession(session);
          }
        } catch (e) {
          session = null;
          saveLocalSession(null);
        }
      }
      emit();
      return session;
    },

    signUp: async function (email, password) {
      if (session) {
        try { await authFetch('/auth/v1/logout', { method: 'POST', body: '{}' }); } catch (e) {}
        session = null;
        saveLocalSession(null);
        emit();
      }
      var body = await authFetch('/auth/v1/signup', {
        method: 'POST',
        body: JSON.stringify({ email: email, password: password })
      });
      // When email confirm is on, session may be null.
      if (body.access_token) {
        session = normalizeSession(body);
        saveLocalSession(session);
        emit();
      } else if (body.user && !body.access_token) {
        return { needsConfirm: true, user: body.user };
      } else if (body.session) {
        session = normalizeSession(body.session);
        if (body.user) session.user = body.user;
        saveLocalSession(session);
        emit();
      }
      return { needsConfirm: false, session: session };
    },

    signIn: async function (email, password) {
      var body = await authFetch('/auth/v1/token?grant_type=password', {
        method: 'POST',
        body: JSON.stringify({ email: email, password: password })
      });
      session = normalizeSession(body);
      saveLocalSession(session);
      emit();
      return session;
    },

    signOut: async function () {
      try {
        if (session) await authFetch('/auth/v1/logout', { method: 'POST', body: '{}' });
      } catch (e) {}
      session = null;
      saveLocalSession(null);
      emit();
    },

    listChats: async function () {
      await refreshIfNeeded();
      if (!session) return [];
      var rows = await rest(
        'chats?select=id,title,client,tier,created_at,updated_at&order=updated_at.desc&limit=50',
        { method: 'GET', headers: { Accept: 'application/json' } }
      );
      return Array.isArray(rows) ? rows : [];
    },

    createChat: async function (opts) {
      await refreshIfNeeded();
      if (!session) throw new Error('Not signed in');
      opts = opts || {};
      var row = {
        user_id: session.user && session.user.id,
        title: opts.title || 'New Chat',
        client: opts.client || 'lab',
        tier: opts.tier || null
      };
      var rows = await rest('chats', {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          Prefer: 'return=representation'
        },
        body: JSON.stringify(row)
      });
      return Array.isArray(rows) ? rows[0] : rows;
    },

    updateChat: async function (id, patch) {
      await refreshIfNeeded();
      if (!session) throw new Error('Not signed in');
      patch = Object.assign({ updated_at: new Date().toISOString() }, patch || {});
      var rows = await rest('chats?id=eq.' + encodeURIComponent(id), {
        method: 'PATCH',
        headers: {
          Accept: 'application/json',
          Prefer: 'return=representation'
        },
        body: JSON.stringify(patch)
      });
      return Array.isArray(rows) ? rows[0] : rows;
    },

    deleteChat: async function (id) {
      await refreshIfNeeded();
      if (!session) throw new Error('Not signed in');
      await rest('chats?id=eq.' + encodeURIComponent(id), { method: 'DELETE' });
    },

    loadMessages: async function (chatId) {
      await refreshIfNeeded();
      if (!session) return [];
      var rows = await rest(
        'chat_messages?chat_id=eq.' + encodeURIComponent(chatId) +
          '&select=id,role,content,sources,seq,created_at&order=seq.asc',
        { method: 'GET', headers: { Accept: 'application/json' } }
      );
      return Array.isArray(rows) ? rows : [];
    },

    /** Replace all messages for a chat (simple durable sync). */
    saveMessages: async function (chatId, messages, meta) {
      await refreshIfNeeded();
      if (!session) throw new Error('Not signed in');
      meta = meta || {};
      if (meta.title || meta.tier) {
        await Cloud.updateChat(chatId, {
          title: meta.title,
          tier: meta.tier
        });
      } else {
        await Cloud.updateChat(chatId, {});
      }
      await rest('chat_messages?chat_id=eq.' + encodeURIComponent(chatId), {
        method: 'DELETE'
      });
      var rows = (messages || []).map(function (m, i) {
        return {
          chat_id: chatId,
          role: m.role === 'user' ? 'user' : (m.role === 'system' ? 'system' : 'assistant'),
          content: String(m.content || '').slice(0, 100000),
          sources: Array.isArray(m.sources) ? m.sources : [],
          seq: i
        };
      });
      if (!rows.length) return [];
      // Insert in chunks to stay under payload limits.
      var saved = [];
      for (var i = 0; i < rows.length; i += 40) {
        var chunk = rows.slice(i, i + 40);
        var out = await rest('chat_messages', {
          method: 'POST',
          headers: {
            Accept: 'application/json',
            Prefer: 'return=representation'
          },
          body: JSON.stringify(chunk)
        });
        if (Array.isArray(out)) saved = saved.concat(out);
      }
      return saved;
    },

    /** 500 MiB per object / per attach batch. */
    MAX_ATTACH_BYTES: 500 * 1024 * 1024,
    ATTACH_BUCKET: 'cs-ai-attachments',

    /**
     * Upload a File/Blob to private storage. Uses resumable TUS when tus-js-client
     * is loaded and the file is > 5 MiB; otherwise a single POST.
     * onProgress(ratio 0..1) optional.
     * Returns { path, name, mime, size, signedUrl }.
     */
    uploadAttachment: async function (file, opts) {
      opts = opts || {};
      await refreshIfNeeded();
      if (!session || !session.user || !session.user.id) {
        throw new Error('Sign in to upload files (up to 500 MB).');
      }
      if (!file || !file.size) throw new Error('Empty file');
      if (file.size > Cloud.MAX_ATTACH_BYTES) {
        throw new Error('Each file must be 500 MB or smaller.');
      }
      var c = await ensureConfig();
      var safeName = String(file.name || 'file').replace(/[^\w.\-()+ ]+/g, '_').slice(0, 180);
      var path = session.user.id + '/' + Date.now().toString(36) + '-' +
        Math.random().toString(36).slice(2, 8) + '-' + safeName;
      var mime = file.type || 'application/octet-stream';

      if (file.size > 5 * 1024 * 1024 && global.tus && global.tus.Upload) {
        await new Promise(function (resolve, reject) {
          var upload = new global.tus.Upload(file, {
            endpoint: c.url + '/storage/v1/upload/resumable',
            retryDelays: [0, 2000, 5000, 10000],
            headers: {
              authorization: 'Bearer ' + session.access_token,
              apikey: c.anonKey,
              'x-upsert': 'true'
            },
            uploadDataDuringCreation: true,
            removeFingerprintOnSuccess: true,
            metadata: {
              bucketName: Cloud.ATTACH_BUCKET,
              objectName: path,
              contentType: mime,
              cacheControl: '3600'
            },
            chunkSize: 6 * 1024 * 1024,
            onError: function (err) { reject(err); },
            onProgress: function (sent, total) {
              if (opts.onProgress && total) opts.onProgress(sent / total);
            },
            onSuccess: function () { resolve(); }
          });
          upload.start();
        });
      } else {
        var res = await fetch(
          c.url + '/storage/v1/object/' + Cloud.ATTACH_BUCKET + '/' + path.split('/').map(encodeURIComponent).join('/'),
          {
            method: 'POST',
            headers: {
              apikey: c.anonKey,
              Authorization: 'Bearer ' + session.access_token,
              'Content-Type': mime,
              'x-upsert': 'true'
            },
            body: file
          }
        );
        if (!res.ok) {
          var t = await res.text().catch(function () { return ''; });
          throw new Error(t || ('Upload failed (' + res.status + ')'));
        }
        if (opts.onProgress) opts.onProgress(1);
      }

      try {
        await rest('chat_attachments', {
          method: 'POST',
          headers: { Accept: 'application/json', Prefer: 'return=minimal' },
          body: JSON.stringify({
            user_id: session.user.id,
            chat_id: opts.chatId || null,
            storage_path: path,
            file_name: safeName,
            mime: mime,
            size_bytes: file.size
          })
        });
      } catch (e) { /* metadata optional */ }

      var signedUrl = await Cloud.createSignedUrl(path, 60 * 60 * 24);
      return {
        path: path,
        name: safeName,
        mime: mime,
        size: file.size,
        signedUrl: signedUrl
      };
    },

    createSignedUrl: async function (path, expiresSec) {
      await refreshIfNeeded();
      if (!session) throw new Error('Not signed in');
      var c = await ensureConfig();
      var body = await fetch(
        c.url + '/storage/v1/object/sign/' + Cloud.ATTACH_BUCKET + '/' +
          path.split('/').map(encodeURIComponent).join('/'),
        {
          method: 'POST',
          headers: {
            apikey: c.anonKey,
            Authorization: 'Bearer ' + session.access_token,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({ expiresIn: expiresSec || 86400 })
        }
      ).then(function (r) { return r.json(); });
      if (!body || !body.signedURL) throw new Error('Could not sign attachment URL');
      var rel = body.signedURL;
      if (/^https?:/i.test(rel)) return rel;
      return c.url + '/storage/v1' + (rel.charAt(0) === '/' ? rel : '/' + rel);
    }
  };

  global.ChopsticksAICloud = Cloud;
})(typeof window !== 'undefined' ? window : globalThis);
