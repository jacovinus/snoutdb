/**
 * Log fixture generator for SnoutDB benchmarks.
 * Generates four formats in parallel: CLF, Combined, Logfmt, Syslog.
 *
 * Usage:
 *   node tools/generate_logs.mjs [row-count]
 *   node tools/generate_logs.mjs 5000000
 *
 * Output files:
 *   tests/fixtures/access_log_<N>.log        — CLF
 *   tests/fixtures/combined_log_<N>.log      — Combined (CLF + referer + UA)
 *   tests/fixtures/app_log_<N>.log           — Logfmt
 *   tests/fixtures/syslog_<N>.log            — Syslog RFC 3164 with PRI prefix
 */

import {createWriteStream} from "node:fs";
import {once} from "node:events";
import {finished} from "node:stream/promises";

const DEFAULT_ROW_COUNT = 50_000;
const BATCH_SIZE = 10_000;

const rowCount = parseRowCount(process.argv[2] ?? String(DEFAULT_ROW_COUNT));
const outputDir = new URL("../tests/fixtures/", import.meta.url);
const stem = `${rowCount}`;

// ---- Deterministic data pools ----------------------------------------------

const IPS = [
  "10.0.0.1", "10.0.0.2", "10.0.0.3", "172.16.0.5", "172.16.0.6",
  "192.168.1.10", "192.168.1.20", "192.168.1.100", "203.0.113.5", "198.51.100.9",
];
const USERS = ["-", "-", "-", "alice", "bob", "carol", "dave", "-", "eve", "-"];
const METHODS = ["GET", "GET", "GET", "POST", "PUT", "DELETE", "GET", "PATCH", "GET", "HEAD"];
const PATHS = [
  "/api/users", "/api/orders", "/api/products", "/api/auth/login",
  "/api/auth/logout", "/dashboard", "/health", "/metrics",
  "/api/users/search", "/api/orders/export",
];
const PROTOCOLS = ["HTTP/1.1", "HTTP/1.1", "HTTP/1.1", "HTTP/2.0", "HTTP/1.1"];
const STATUSES = [200, 200, 200, 201, 204, 301, 400, 401, 403, 404, 500, 503];
const REFERERS = [
  "-", "-", "https://example.com/", "https://example.com/dashboard",
  "https://example.com/login", "-", "https://partner.io/",
];
const USER_AGENTS = [
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/537.36 Chrome/120",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120",
  "curl/7.88.1",
  "python-requests/2.31.0",
  "Go-http-client/2.0",
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) AppleWebKit/605 Safari/604",
];
const LOG_LEVELS = ["info", "info", "info", "warn", "error", "debug", "info"];
const SERVICES = ["api-gateway", "auth-service", "order-service", "user-service", "scheduler"];
const REGIONS = ["us-east", "us-west", "eu-west", "ap-south", "latam"];
const MESSAGES = [
  "request complete",
  "cache miss",
  "db query slow",
  "connection timeout",
  "retrying upstream",
  "rate limit exceeded",
  "auth token refreshed",
  "session expired",
];
const SYSLOG_APPS = ["nginx", "sshd", "cron", "kernel", "systemd", "myapp", "postgres"];
const SYSLOG_MESSAGES = [
  "worker process started",
  "connection established",
  "failed password for root",
  "session opened for user alice",
  "disk usage above 80%",
  "reloading configuration",
  "starting backup job",
  "health check passed",
];
const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

// ---- Time helpers ----------------------------------------------------------

const BASE_MS = Date.parse("2026-01-01T00:00:00Z");

function rowToMs(index) {
  return BASE_MS + index * 1_000; // 1 second per row
}

function clfTimestamp(ms) {
  const d = new Date(ms);
  const day = String(d.getUTCDate()).padStart(2, "0");
  const mon = MONTHS[d.getUTCMonth()];
  const year = d.getUTCFullYear();
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  const ss = String(d.getUTCSeconds()).padStart(2, "0");
  return `${day}/${mon}/${year}:${hh}:${mm}:${ss} +0000`;
}

function isoTimestamp(ms) {
  return new Date(ms).toISOString().replace(".000Z", "Z");
}

function syslogTimestamp(ms) {
  const d = new Date(ms);
  const mon = MONTHS[d.getUTCMonth()];
  const day = String(d.getUTCDate()).padStart(2, " "); // RFC 3164 space-padded
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  const ss = String(d.getUTCSeconds()).padStart(2, "0");
  return `${mon} ${day} ${hh}:${mm}:${ss}`;
}

// ---- Row builders ----------------------------------------------------------

function pick(arr, index, salt = 1) {
  return arr[Math.abs((index * salt + Math.floor(index / 13)) % arr.length)];
}

function makeRow(index) {
  const ms = rowToMs(index);
  const ip = pick(IPS, index, 7);
  const user = pick(USERS, index, 3);
  const method = pick(METHODS, index, 5);
  const path = pick(PATHS, index, 11);
  const protocol = pick(PROTOCOLS, index, 2);
  const status = pick(STATUSES, index, 13);
  const bytes = status === 204 ? null : 200 + ((index * 97) % 49_800);
  const referer = pick(REFERERS, index, 17);
  const ua = pick(USER_AGENTS, index, 23);
  const latency = 5 + ((index * 41) % 995);
  const level = pick(LOG_LEVELS, index, 19);
  const service = pick(SERVICES, index, 29);
  const region = pick(REGIONS, index, 37);
  const msg = pick(MESSAGES, index, 43);
  const syslogApp = pick(SYSLOG_APPS, index, 53);
  const syslogMsg = pick(SYSLOG_MESSAGES, index, 59);
  const pid = 1000 + ((index * 61) % 59000);
  // PRI: facility (daemon=3 → 3*8=24) + severity (varies)
  const severity = status >= 500 ? 3 : status >= 400 ? 4 : level === "warn" ? 5 : 6;
  const pri = 24 + severity;

  return {
    ms, ip, user, method, path, protocol, status, bytes, referer, ua,
    latency, level, service, region, msg, syslogApp, syslogMsg, pid, pri,
  };
}

// ---- Format renderers ------------------------------------------------------

function clfLine(r) {
  const user = r.user === "-" ? "-" : r.user;
  const bytes = r.bytes === null ? "-" : String(r.bytes);
  return `${r.ip} - ${user} [${clfTimestamp(r.ms)}] "${r.method} ${r.path} ${r.protocol}" ${r.status} ${bytes}`;
}

function combinedLine(r) {
  const referer = r.referer === "-" ? `"-"` : `"${r.referer}"`;
  return `${clfLine(r)} ${referer} "${r.ua}"`;
}

function logfmtLine(r) {
  // Wrap msg in quotes if it contains spaces.
  const msgVal = r.msg.includes(" ") ? `"${r.msg}"` : r.msg;
  return `ts=${isoTimestamp(r.ms)} level=${r.level} service=${r.service} region=${r.region} msg=${msgVal} method=${r.method} path=${r.path} status=${r.status} latency_ms=${r.latency} bytes=${r.bytes ?? 0}`;
}

function syslogLine(r) {
  return `<${r.pri}>${syslogTimestamp(r.ms)} ${r.ip} ${r.syslogApp}[${r.pid}]: ${r.syslogMsg}`;
}

// ---- Writer helpers --------------------------------------------------------

async function writeChunk(stream, chunk) {
  if (!stream.write(chunk)) {
    await once(stream, "drain");
  }
}

function parseRowCount(value) {
  if (!/^[1-9]\d*$/.test(value)) {
    throw new Error(`row count must be a positive integer, received: ${value}`);
  }
  const n = Number(value);
  if (!Number.isSafeInteger(n)) throw new Error(`row count too large: ${value}`);
  return n;
}

// ---- Main ------------------------------------------------------------------

const paths = {
  clf:      new URL(`access_log_${stem}.log`,   outputDir),
  combined: new URL(`combined_log_${stem}.log`, outputDir),
  logfmt:   new URL(`app_log_${stem}.log`,      outputDir),
  syslog:   new URL(`syslog_${stem}.log`,       outputDir),
};

const streams = {
  clf:      createWriteStream(paths.clf,      {encoding: "utf8"}),
  combined: createWriteStream(paths.combined, {encoding: "utf8"}),
  logfmt:   createWriteStream(paths.logfmt,   {encoding: "utf8"}),
  syslog:   createWriteStream(paths.syslog,   {encoding: "utf8"}),
};

try {
  for (let batchStart = 0; batchStart < rowCount; batchStart += BATCH_SIZE) {
    const batchEnd = Math.min(rowCount, batchStart + BATCH_SIZE);
    const lines = {clf: [], combined: [], logfmt: [], syslog: []};

    for (let i = batchStart; i < batchEnd; i++) {
      const r = makeRow(i);
      lines.clf.push(clfLine(r));
      lines.combined.push(combinedLine(r));
      lines.logfmt.push(logfmtLine(r));
      lines.syslog.push(syslogLine(r));
    }

    await Promise.all([
      writeChunk(streams.clf,      lines.clf.join("\n")      + "\n"),
      writeChunk(streams.combined, lines.combined.join("\n") + "\n"),
      writeChunk(streams.logfmt,   lines.logfmt.join("\n")   + "\n"),
      writeChunk(streams.syslog,   lines.syslog.join("\n")   + "\n"),
    ]);

    if (batchEnd === rowCount || batchEnd % 100_000 === 0) {
      process.stderr.write(
        `generated ${batchEnd.toLocaleString("en-US")} / ${rowCount.toLocaleString("en-US")} rows\r`,
      );
    }
  }

  for (const s of Object.values(streams)) s.end();
  await Promise.all(Object.values(streams).map(s => finished(s)));
  process.stderr.write("\n");

  for (const [fmt, p] of Object.entries(paths)) {
    console.log(`written [${fmt.padEnd(8)}]: ${p.pathname}`);
  }
} catch (err) {
  for (const s of Object.values(streams)) s.destroy();
  throw err;
}
