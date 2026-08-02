/**
 * Same-origin Minecraft status for chopstickshq.com/minecraft
 * GET /.netlify/functions/mc-status?host=catboigens.minefort.com
 *
 * Accuracy stack (probed in parallel):
 *   1. direct-slp     — TCP Server List Ping (best when Netlify can reach :25565)
 *   2. minetools.eu   — live ping + player sample (very reliable for Velocity)
 *   3. mc-api.net     — EU ping API with sample list
 *   4. mcstatus.io    — solid secondary (can briefly cache offline)
 *
 * mcsrvstat.us is intentionally NOT used — often false-offline on Minefort.
 *
 * Online: trusted sources (SLP / minetools / mc-api) win over flaky offline votes.
 * Player count: median of online votes (less skew than max).
 * Names/version: prefer direct-slp, then richest sample.
 */
const dns = require("dns").promises;
const net = require("net");

const ALLOWED = new Set([
  "catboigens.minefort.com",
  "spleengens.minefort.com",
  "macetech.minefort.com",
  "macetechsmp.minefort.com",
  "jupitergens.minefort.com",
  "marsgens.minefort.com",
  "freegens.minefort.com",
  "krunkgens.minefort.com",
  "minecraft.lazygenz.scalacubes.xyz",
]);

const UA = "chopstickshq-minecraft-telemetry/3.1";
const FETCH_MS = 4500;
const SLP_MS = 2500; // fail fast on Netlify (Minefort often blocks AWS :25565)

const SOURCE_RANK = {
  "direct-slp": 6,
  "minetools.eu": 5,
  "mc-api.net": 4,
  "mcstatus.io": 3,
};

const TRUSTED_ONLINE = new Set(["direct-slp", "minetools.eu", "mc-api.net"]);

function json(statusCode, body) {
  return {
    statusCode,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=12, stale-while-revalidate=25",
      "Access-Control-Allow-Origin": "*",
    },
    body: JSON.stringify(body),
  };
}

async function fetchJson(url) {
  const ctrl = new AbortController();
  const t = setTimeout(function () {
    ctrl.abort();
  }, FETCH_MS);
  try {
    const res = await fetch(url, {
      headers: { Accept: "application/json", "User-Agent": UA },
      signal: ctrl.signal,
    });
    if (!res.ok) return null;
    return await res.json();
  } catch (_) {
    return null;
  } finally {
    clearTimeout(t);
  }
}

/* ── SLP ────────────────────────────────────────────────────── */

function writeVarInt(value) {
  const out = [];
  let v = value >>> 0;
  while (true) {
    if ((v & ~0x7f) === 0) {
      out.push(v);
      break;
    }
    out.push((v & 0x7f) | 0x80);
    v >>>= 7;
  }
  return Buffer.from(out);
}

function writeString(str) {
  const b = Buffer.from(str, "utf8");
  return Buffer.concat([writeVarInt(b.length), b]);
}

function writeUnsignedShort(n) {
  const b = Buffer.alloc(2);
  b.writeUInt16BE(n & 0xffff, 0);
  return b;
}

function packet(id, data) {
  const idBuf = writeVarInt(id);
  return Buffer.concat([writeVarInt(idBuf.length + data.length), idBuf, data]);
}

function readVarInt(buf, offset) {
  let numRead = 0;
  let result = 0;
  let read;
  do {
    if (offset + numRead >= buf.length) return null;
    read = buf[offset + numRead];
    result |= (read & 0x7f) << (7 * numRead);
    numRead++;
    if (numRead > 5) throw new Error("VarInt too big");
  } while ((read & 0x80) !== 0);
  return { value: result >>> 0, size: numRead };
}

async function resolveConnectTargets(host, defaultPort) {
  const targets = [];
  const seen = Object.create(null);

  function add(address, port, via) {
    if (!address) return;
    const key = address + ":" + port;
    if (seen[key]) return;
    seen[key] = true;
    targets.push({ address: address, port: port || defaultPort, via: via });
  }

  try {
    const srv = await dns.resolveSrv("_minecraft._tcp." + host);
    if (srv && srv.length) {
      srv.sort(function (a, b) {
        if (a.priority !== b.priority) return a.priority - b.priority;
        return b.weight - a.weight;
      });
      for (let i = 0; i < Math.min(srv.length, 2); i++) {
        const pick = srv[i];
        try {
          const a = await dns.resolve4(pick.name);
          if (a && a[0]) add(a[0], pick.port || defaultPort, "srv");
        } catch (_) {
          add(pick.name, pick.port || defaultPort, "srv-name");
        }
      }
    }
  } catch (_) {
    /* no SRV */
  }

  try {
    const a = await dns.resolve4(host);
    for (let i = 0; i < Math.min(a.length, 2); i++) add(a[i], defaultPort, "a");
  } catch (_) {
    add(host, defaultPort, "host");
  }

  return targets.length ? targets : [{ address: host, port: defaultPort, via: "host" }];
}

function javaSlpOnce(handshakeHost, connect, timeoutMs) {
  const port = connect.port || 25565;
  const connectHost = connect.address;
  const protocol = 47;

  return new Promise(function (resolve, reject) {
    const socket = net.createConnection({ host: connectHost, port: port });
    let buf = Buffer.alloc(0);
    let done = false;

    const finish = function (err, data) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        socket.destroy();
      } catch (_) {}
      if (err) reject(err);
      else resolve(data);
    };

    const timer = setTimeout(function () {
      finish(new Error("slp timeout"));
    }, timeoutMs);

    socket.setNoDelay(true);
    socket.setTimeout(timeoutMs);

    socket.on("connect", function () {
      const hs = Buffer.concat([
        writeVarInt(protocol),
        writeString(handshakeHost),
        writeUnsignedShort(port),
        writeVarInt(1),
      ]);
      socket.write(packet(0x00, hs));
      socket.write(packet(0x00, Buffer.alloc(0)));
    });

    socket.on("data", function (chunk) {
      buf = Buffer.concat([buf, chunk]);
      try {
        const len = readVarInt(buf, 0);
        if (!len || buf.length < len.size + len.value) return;
        const packetBuf = buf.slice(len.size, len.size + len.value);
        const pid = readVarInt(packetBuf, 0);
        if (!pid) return;
        const strMeta = readVarInt(packetBuf, pid.size);
        if (!strMeta) return;
        const start = pid.size + strMeta.size;
        const jsonStr = packetBuf
          .slice(start, start + strMeta.value)
          .toString("utf8");
        finish(null, JSON.parse(jsonStr));
      } catch (_) {}
    });

    socket.on("timeout", function () {
      finish(new Error("slp socket timeout"));
    });
    socket.on("error", function (e) {
      finish(e);
    });
    socket.on("close", function () {
      if (!done) finish(new Error("slp closed without response"));
    });
  });
}

/** Race multiple connect targets; first successful status wins. */
async function javaSlp(handshakeHost) {
  const targets = await resolveConnectTargets(handshakeHost, 25565);
  return new Promise(function (resolve, reject) {
    let remaining = targets.length;
    let settled = false;
    if (!remaining) {
      reject(new Error("no connect targets"));
      return;
    }
    targets.forEach(function (connect) {
      javaSlpOnce(handshakeHost, connect, SLP_MS)
        .then(function (raw) {
          if (settled) return;
          // Reject Minefort "wrong vhost" offline shell
          const ver =
            raw && raw.version && (raw.version.name || raw.version);
          const players = (raw && raw.players) || {};
          const onlineN = typeof players.online === "number" ? players.online : 0;
          const maxN = typeof players.max === "number" ? players.max : 0;
          if (
            ver &&
            /offline/i.test(String(ver)) &&
            onlineN === 0 &&
            maxN === 0
          ) {
            remaining--;
            if (!remaining && !settled) reject(new Error("slp offline shell"));
            return;
          }
          settled = true;
          resolve({ raw: raw, connect: connect });
        })
        .catch(function () {
          remaining--;
          if (!remaining && !settled) reject(new Error("slp timeout"));
        });
    });
  });
}

/* ── normalize ──────────────────────────────────────────────── */

function playerNamesFromList(list) {
  if (!Array.isArray(list) || !list.length) return [];
  const out = [];
  const seen = Object.create(null);
  for (let i = 0; i < list.length; i++) {
    const p = list[i];
    let name = null;
    let uuid;
    if (typeof p === "string" && p) {
      name = p;
    } else if (p && typeof p === "object") {
      name = p.name_clean || p.name || p.name_raw || p.username || null;
      uuid = p.uuid || p.id || undefined;
    }
    if (!name) continue;
    name = String(name);
    const key = name.toLowerCase();
    if (seen[key]) continue;
    seen[key] = true;
    out.push(uuid ? { name: name, uuid: String(uuid) } : { name: name });
  }
  return out;
}

function failedSnapshot(source, host, reason) {
  return {
    source: source,
    online: false,
    hostname: host,
    players: { online: 0, max: 0, list: [] },
    motd: { clean: [] },
    version: "—",
    ok: false,
    error: reason || "upstream failed",
  };
}

function snapshot(source, online, host, fields) {
  fields = fields || {};
  const players = fields.players || { online: 0, max: 0, list: [] };
  return {
    source: source,
    online: !!online,
    hostname: fields.hostname || host,
    ip: fields.ip || null,
    port: typeof fields.port === "number" ? fields.port : 25565,
    version: fields.version || "—",
    protocol: fields.protocol,
    software: fields.software || null,
    players: {
      online: online ? (typeof players.online === "number" ? players.online : 0) : 0,
      max: typeof players.max === "number" ? players.max : 0,
      list: online ? players.list || [] : [],
    },
    motd: fields.motd || { clean: [] },
    icon: fields.icon || null,
    ok: true,
    latency_ms: fields.latency_ms,
  };
}

function motdFromDescription(desc) {
  if (desc == null) return { clean: [] };
  if (typeof desc === "string") {
    return { clean: [desc.replace(/\u00a7./g, "")] };
  }
  if (typeof desc === "object") {
    if (typeof desc.text === "string" && !desc.extra) {
      return { clean: [desc.text.replace(/\u00a7./g, "")] };
    }
    let s = "";
    const walk = function (n) {
      if (!n) return;
      if (typeof n === "string") {
        s += n;
        return;
      }
      if (n.text) s += n.text;
      if (Array.isArray(n.extra)) n.extra.forEach(walk);
    };
    walk(desc);
    s = s.replace(/\u00a7./g, "").trim();
    return { clean: s ? [s] : [] };
  }
  return { clean: [] };
}

function fromDirectSlp(raw, host, connect) {
  if (!raw || typeof raw !== "object") {
    return failedSnapshot("direct-slp", host, "empty response");
  }
  const players = raw.players || {};
  const list = playerNamesFromList(players.sample || players.list || []);
  const onlineN = typeof players.online === "number" ? players.online : list.length;
  const maxN = typeof players.max === "number" ? players.max : 0;
  const verName = (raw.version && (raw.version.name || raw.version)) || null;
  const verStr = verName ? String(verName) : "—";
  const looksOffline =
    /offline/i.test(verStr) && onlineN === 0 && maxN === 0 && !list.length;
  const online = !looksOffline;
  return snapshot("direct-slp", online, host, {
    hostname: host,
    ip: connect && connect.address,
    port: connect && connect.port,
    version: looksOffline ? "—" : verStr,
    protocol: raw.version
      ? { name: verStr, version: raw.version.protocol }
      : verStr !== "—"
        ? { name: verStr }
        : undefined,
    software:
      !looksOffline && verStr && /velocity/i.test(verStr)
        ? "Velocity"
        : raw.software || null,
    players: { online: onlineN, max: maxN, list: list },
    motd: motdFromDescription(raw.description),
    icon: raw.favicon || null,
  });
}

function fromMcstatusIo(d, host) {
  if (!d || typeof d !== "object") return failedSnapshot("mcstatus.io", host);
  const online = !!d.online;
  const players = d.players || {};
  const list = playerNamesFromList(players.list);
  const onlineN = typeof players.online === "number" ? players.online : list.length;
  const maxN = typeof players.max === "number" ? players.max : 0;
  const ver =
    (d.version && (d.version.name_clean || d.version.name_raw || d.version.name)) ||
    null;
  const motdClean =
    d.motd && d.motd.clean
      ? Array.isArray(d.motd.clean)
        ? d.motd.clean
        : [String(d.motd.clean)]
      : [];
  return snapshot("mcstatus.io", online, host, {
    hostname: d.host || host,
    ip: d.ip_address || d.ip || null,
    port: typeof d.port === "number" ? d.port : 25565,
    version: ver || "—",
    protocol: ver ? { name: ver, version: d.version && d.version.protocol } : undefined,
    software:
      d.software || (ver && /velocity/i.test(ver) ? "Velocity" : null) || null,
    players: { online: onlineN, max: maxN, list: list },
    motd: {
      clean: motdClean,
      raw: d.motd && d.motd.raw ? [String(d.motd.raw)] : [],
    },
    icon: d.icon || null,
  });
}

function fromMinetools(d, host) {
  if (!d || typeof d !== "object") return failedSnapshot("minetools.eu", host);
  if (d.error && d.players == null && d.online !== true) {
    return snapshot("minetools.eu", false, host, {});
  }
  const players = d.players || {};
  const list = playerNamesFromList(players.sample || players.list || []);
  const onlineN = typeof players.online === "number" ? players.online : list.length;
  const maxN = typeof players.max === "number" ? players.max : 0;
  const description =
    typeof d.description === "string"
      ? d.description
      : d.description && d.description.text
        ? d.description.text
        : null;
  const ver =
    (d.version && (d.version.name || d.version)) ||
    (typeof d.version === "string" ? d.version : null);
  const online =
    d.online === true ||
    (d.online !== false &&
      !d.error &&
      (onlineN > 0 || !!ver || !!description || d.favicon != null || d.latency != null));
  return snapshot("minetools.eu", online, host, {
    version: ver ? String(ver) : "—",
    protocol: ver ? { name: String(ver) } : undefined,
    software: ver && /velocity/i.test(String(ver)) ? "Velocity" : null,
    players: { online: onlineN, max: maxN, list: list },
    motd: {
      clean: description ? [String(description).replace(/\u00a7./g, "")] : [],
    },
    latency_ms: typeof d.latency === "number" ? Math.round(d.latency) : undefined,
  });
}

function fromMcApiNet(d, host) {
  if (!d || typeof d !== "object") return failedSnapshot("mc-api.net", host);
  const online = !!(d.online || d.status);
  const players = d.players || {};
  const list = playerNamesFromList(players.sample || players.list || []);
  const onlineN = typeof players.online === "number" ? players.online : list.length;
  const maxN = typeof players.max === "number" ? players.max : 0;
  const ver = (d.version && (d.version.name || d.version)) || null;
  return snapshot("mc-api.net", online, host, {
    version: ver ? String(ver) : "—",
    protocol: ver
      ? { name: String(ver), version: d.version && d.version.protocol }
      : undefined,
    software: ver && /velocity/i.test(String(ver)) ? "Velocity" : null,
    players: { online: onlineN, max: maxN, list: list },
    motd: motdFromDescription(d.description),
    icon: d.favicon || null,
    latency_ms: typeof d.took === "number" ? Math.round(d.took) : undefined,
  });
}

function rankOf(r) {
  return SOURCE_RANK[r.source] || 0;
}

function median(nums) {
  if (!nums.length) return 0;
  const a = nums.slice().sort(function (x, y) {
    return x - y;
  });
  const m = Math.floor(a.length / 2);
  if (a.length % 2) return a[m];
  return Math.round((a[m - 1] + a[m]) / 2);
}

function mergeConsensus(results) {
  const sources = results.map(function (r) {
    return {
      name: r.source,
      ok: !!r.ok,
      online: !!r.online && !!r.ok,
      players: r.players ? r.players.online : 0,
      max: r.players ? r.players.max : 0,
      version: r.version || null,
      error: r.error || undefined,
    };
  });

  const responding = results.filter(function (r) {
    return r && r.ok;
  });
  if (!responding.length) return null;

  const onlineVotes = responding.filter(function (r) {
    return r.online;
  });
  const offlineVotes = responding.length - onlineVotes.length;

  const trustedOnline = onlineVotes.some(function (r) {
    return TRUSTED_ONLINE.has(r.source);
  });
  // If a trusted source says online, ignore flaky offline caches (mcstatus, etc.)
  let consensusOnline = trustedOnline || onlineVotes.length > offlineVotes;
  if (!trustedOnline && onlineVotes.length === offlineVotes) {
    consensusOnline = onlineVotes.some(function (r) {
      return (r.players && r.players.online) > 0;
    });
  }
  if (responding.length === 1) consensusOnline = !!responding[0].online;

  const pool = consensusOnline && onlineVotes.length ? onlineVotes : responding;
  pool.sort(function (a, b) {
    const ar = rankOf(a);
    const br = rankOf(b);
    if (br !== ar) return br - ar;
    const al = (a.players && a.players.list && a.players.list.length) || 0;
    const bl = (b.players && b.players.list && b.players.list.length) || 0;
    if (bl !== al) return bl - al;
    const ap = (a.players && a.players.online) || 0;
    const bp = (b.players && b.players.online) || 0;
    return bp - ap;
  });

  const best = Object.assign({}, pool[0]);
  best.online = consensusOnline;

  const enrichFrom = consensusOnline ? onlineVotes : pool;
  const counts = [];
  let maxSlots = 0;
  const listMap = Object.create(null);
  const listOut = [];

  // Prefer direct-slp count when present
  const slp = onlineVotes.find(function (r) {
    return r.source === "direct-slp";
  });

  for (let i = 0; i < enrichFrom.length; i++) {
    const r = enrichFrom[i];
    if (!r.players) continue;
    if (typeof r.players.online === "number") counts.push(r.players.online);
    if (typeof r.players.max === "number" && r.players.max > maxSlots) {
      maxSlots = r.players.max;
    }
    const L = r.players.list || [];
    for (let j = 0; j < L.length; j++) {
      const p = L[j];
      const name = p && p.name ? p.name : String(p);
      const key = name.toLowerCase();
      if (!listMap[key]) {
        listMap[key] = true;
        listOut.push(typeof p === "object" ? p : { name: name });
      }
    }
  }

  let onlineCount = median(counts);
  if (slp && slp.players && typeof slp.players.online === "number") {
    onlineCount = slp.players.online;
    if (slp.players.max) maxSlots = slp.players.max;
  }

  best.players = {
    online: consensusOnline ? onlineCount : 0,
    max: maxSlots || (best.players && best.players.max) || 0,
    list: consensusOnline ? listOut : [],
  };

  if (consensusOnline) {
    onlineVotes
      .slice()
      .sort(function (a, b) {
        return rankOf(b) - rankOf(a);
      })
      .forEach(function (r) {
        if ((!best.version || best.version === "—") && r.version && r.version !== "—") {
          best.version = r.version;
          best.protocol = r.protocol || { name: r.version };
        }
        if (!best.software && r.software) best.software = r.software;
        if (
          (!best.motd || !best.motd.clean || !best.motd.clean.length) &&
          r.motd &&
          r.motd.clean &&
          r.motd.clean.length
        ) {
          best.motd = r.motd;
        }
        if (!best.ip && r.ip) best.ip = r.ip;
        if (!best.hostname && r.hostname) best.hostname = r.hostname;
      });
    if (best.software == null && best.version && /velocity/i.test(best.version)) {
      best.software = "Velocity";
    }
  } else {
    best.players.online = 0;
    best.players.list = [];
  }

  best.sources = sources;
  best.consensus = {
    online: consensusOnline,
    responding: responding.length,
    total: results.length,
    online_votes: onlineVotes.length,
    offline_votes: offlineVotes,
    agreement:
      responding.length > 0
        ? Math.round(
            (Math.max(onlineVotes.length, offlineVotes) / responding.length) * 100
          )
        : 0,
  };
  best.sources_checked = sources.map(function (s) {
    return s.name;
  });
  delete best.ok;
  delete best.error;
  return best;
}

async function probeDirectSlp(host) {
  try {
    const { raw, connect } = await javaSlp(host);
    return fromDirectSlp(raw, host, connect);
  } catch (e) {
    return failedSnapshot(
      "direct-slp",
      host,
      String(e && e.message ? e.message : e)
    );
  }
}

exports.handler = async function (event) {
  if (event.httpMethod === "OPTIONS") {
    return {
      statusCode: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
      },
      body: "",
    };
  }

  const rawQ =
    (event.queryStringParameters && event.queryStringParameters.host) ||
    "catboigens.minefort.com";
  const host = String(rawQ)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, "");

  if (!host || !ALLOWED.has(host)) {
    return json(400, { online: false, error: "host not allowed" });
  }

  try {
    const enc = encodeURIComponent(host);
    const [slpSnap, mtRaw, mcApiRaw, ioRaw] = await Promise.all([
      probeDirectSlp(host),
      fetchJson("https://api.minetools.eu/ping/" + enc),
      fetchJson("https://eu.mc-api.net/v3/server/ping/" + enc),
      fetchJson("https://api.mcstatus.io/v2/status/java/" + enc),
    ]);

    const merged = mergeConsensus([
      slpSnap,
      fromMinetools(mtRaw, host),
      fromMcApiNet(mcApiRaw, host),
      fromMcstatusIo(ioRaw, host),
    ]);

    if (!merged) {
      return json(502, {
        online: false,
        hostname: host,
        error: "all upstream status providers failed",
        players: { online: 0, max: 0, list: [] },
        motd: { clean: [] },
        sources: [
          { name: "direct-slp", ok: false, online: false },
          { name: "minetools.eu", ok: false, online: false },
          { name: "mc-api.net", ok: false, online: false },
          { name: "mcstatus.io", ok: false, online: false },
        ],
        consensus: {
          online: false,
          responding: 0,
          total: 4,
          online_votes: 0,
          offline_votes: 0,
        },
      });
    }

    if (!merged.hostname) merged.hostname = host;
    return json(200, merged);
  } catch (err) {
    return json(502, {
      online: false,
      hostname: host,
      error: "upstream status failed",
      detail: String(err && err.message ? err.message : err),
      players: { online: 0, max: 0, list: [] },
      motd: { clean: [] },
    });
  }
};
