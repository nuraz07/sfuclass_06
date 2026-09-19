// server/src/mediasoup/recording/captureAgent.js
//
// Process of the capture sidecar (image: server/Dockerfile.capture). Runs next to the SFU container in the
// same ECS task (host networking, one task per instance) and turns plain RTP from mediasoup into media
// segments on the task's shared scratch volume:
//
//   SFU (PlainTransportRecorder.js)                 capture sidecar (this file)
//   1. picks free loopback RTP ports, builds SDP  →  POST /captures { captureId, sdp }
//                                                     writes the SDP, starts one ffmpeg per capture
//   2. connects PlainTransports to those ports,
//      requests a key frame                         ffmpeg: RTP → Matroska segments (stream copy, no transcode)
//   3. recordingPipeline.js uploads every segment     /scratch/<captureId>/seg-000001.mkv …
//      listed in segments.csv to S3, deletes it      /scratch/<captureId>/segments.csv  (one line per closed segment)
//   4. DELETE /captures/<captureId>               →  ffmpeg finalises the last segment, DONE file is written
//      recordingWorker (worker service) muxes the uploaded segments into the replayable asset.
//
// Nothing durable lives here: segments leave the volume as soon as they are uploaded, and a replaced task loses
// at most the segment being written.
//
// Security: listens on 127.0.0.1 only; optional shared token (CAPTURE_AGENT_TOKEN, same value in the SFU
// container). The SDP is parsed strictly — only loopback addresses and ports inside the configured RTP range —
// and ffmpeg may only use the file, udp and rtp protocols, so a request can never make ffmpeg read or send
// anything else.
//
// Environment:
//   CAPTURE_LISTEN_PORT     7460
//   CAPTURE_SCRATCH_DIR     /scratch          shared task volume (also mounted in the SFU container)
//   CAPTURE_MAX_SESSIONS    32
//   CAPTURE_SEGMENT_SECONDS 6
//   CAPTURE_RTP_PORT_MIN    45000             must match the SFU's recording port range
//   CAPTURE_RTP_PORT_MAX    45999
//   CAPTURE_STOP_TIMEOUT_MS 10000             time ffmpeg gets to finalise before SIGKILL
//   CAPTURE_AGENT_TOKEN     optional bearer token
//   FFMPEG_PATH             ffmpeg
//
// No npm dependencies: Node.js standard library only, so the image contains Node, ffmpeg and this file.
// Owner: F1 Live Classrooms + F4 Media Support.

import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdir, writeFile, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { timingSafeEqual } from 'node:crypto';

const env = process.env;
const config = Object.freeze({
  port: int(env.CAPTURE_LISTEN_PORT, 7460),
  scratch: env.CAPTURE_SCRATCH_DIR ?? '/scratch',
  maxSessions: int(env.CAPTURE_MAX_SESSIONS, 32),
  segmentSeconds: int(env.CAPTURE_SEGMENT_SECONDS, 6),
  rtpPortMin: int(env.CAPTURE_RTP_PORT_MIN, 45_000),
  rtpPortMax: int(env.CAPTURE_RTP_PORT_MAX, 45_999),
  stopTimeoutMs: int(env.CAPTURE_STOP_TIMEOUT_MS, 10_000),
  token: env.CAPTURE_AGENT_TOKEN || null,
  ffmpeg: env.FFMPEG_PATH || 'ffmpeg',
});

const CAPTURE_ID = /^[A-Za-z0-9_-]{8,64}$/;
const MAX_SDP_BYTES = 16 * 1024;

/** @type {Map<string, { child: import('node:child_process').ChildProcess, dir: string, state: string,
 *  startedAt: number, exitCode: number | null, exited: Promise<void>, ports: number[] }>} */
const captures = new Map();
let shuttingDown = false;

process.umask(0o002); // segments must be readable and deletable by the SFU container (shared group)
process.stdout.on('error', () => {}); // a closed log pipe must never crash a running capture

function log(level, msg, fields = {}) {
  process.stdout.write(`${JSON.stringify({ level, service: 'capture', msg, ...fields, time: new Date().toISOString() })}\n`);
}

// ------------------------------------------------------------------ SDP validation

/**
 * Accepts only what mediasoup's PlainTransportRecorder produces: loopback connection data, audio/video RTP
 * media sections on ports inside the recording range, standard attributes. Returns the RTP ports.
 */
export function validateSdp(sdp, { rtpPortMin, rtpPortMax }) {
  if (typeof sdp !== 'string' || sdp.length === 0 || Buffer.byteLength(sdp) > MAX_SDP_BYTES) {
    throw badRequest('sdp must be a non-empty string of at most 16 KiB');
  }
  const lines = sdp.replace(/\r\n/g, '\n').split('\n').filter(Boolean);
  if (lines[0] !== 'v=0') throw badRequest('sdp must start with v=0');
  const ports = [];
  let sawConnection = false;
  for (const line of lines) {
    const type = line.slice(0, 2);
    if (!['v=', 'o=', 's=', 'c=', 't=', 'm=', 'a=', 'b='].includes(type)) throw badRequest(`sdp line type not allowed: ${type}`);
    if (type === 'c=') {
      if (!/^c=IN IP4 127\.0\.0\.1$/.test(line)) throw badRequest('sdp connection address must be 127.0.0.1');
      sawConnection = true;
    }
    if (type === 'o=' && !/^o=\S+ \d+ \d+ IN IP4 127\.0\.0\.1$/.test(line)) throw badRequest('sdp origin must be loopback');
    if (type === 'm=') {
      const match = /^m=(audio|video) (\d+) RTP\/AVPF? [\d ]+$/.exec(line);
      if (!match) throw badRequest('sdp media must be audio/video over RTP/AVP(F)');
      const port = Number(match[2]);
      if (port < rtpPortMin || port > rtpPortMax - 1) throw badRequest(`rtp port ${port} outside ${rtpPortMin}-${rtpPortMax - 1}`);
      ports.push(port);
    }
    if (type === 'a=' && /^a=(rtcp:\d+ IN IP4 (?!127\.0\.0\.1)|source-filter|x-)/.test(line)) {
      throw badRequest('sdp attribute not allowed');
    }
  }
  if (!sawConnection) throw badRequest('sdp needs c=IN IP4 127.0.0.1');
  if (ports.length === 0 || ports.length > 8) throw badRequest('sdp needs 1-8 media sections');
  return ports;
}

// ------------------------------------------------------------------ capture lifecycle

async function startCapture(captureId, sdp) {
  if (captures.has(captureId)) throw httpError(409, 'CAPTURE_EXISTS', 'capture already running');
  if (captures.size >= config.maxSessions) throw httpError(429, 'CAPTURE_LIMIT', `at most ${config.maxSessions} captures per node`);
  const ports = validateSdp(sdp, config);
  const busy = new Set([...captures.values()].flatMap((c) => c.ports));
  if (ports.some((p) => busy.has(p) || busy.has(p + 1))) throw httpError(409, 'PORT_IN_USE', 'rtp port already used by another capture');

  const dir = join(config.scratch, captureId);
  await mkdir(dir, { recursive: true, mode: 0o2775 });
  const sdpPath = join(dir, 'input.sdp');
  await writeFile(sdpPath, sdp, { mode: 0o664 });

  const args = [
    '-hide_banner', '-nostdin', '-loglevel', 'warning',
    '-protocol_whitelist', 'file,udp,rtp',
    '-fflags', '+genpts',
    '-i', sdpPath,
    '-map', '0',
    '-c', 'copy',
    '-f', 'segment',
    '-segment_time', String(config.segmentSeconds),
    '-segment_format', 'matroska',
    '-reset_timestamps', '0',
    '-segment_list', join(dir, 'segments.csv'),
    '-segment_list_type', 'csv',
    join(dir, 'seg-%06d.mkv'),
  ];
  const child = spawn(config.ffmpeg, args, { stdio: ['ignore', 'ignore', 'pipe'] });
  const entry = { child, dir, state: 'running', startedAt: Date.now(), exitCode: null, ports, exited: null };
  entry.exited = new Promise((resolve) => {
    child.once('exit', async (code, signal) => {
      entry.exitCode = code ?? (signal ? 128 : 1);
      entry.state = entry.state === 'stopping' || code === 0 || code === 255 ? 'finished' : 'failed';
      await writeFile(join(dir, 'DONE'), JSON.stringify({ state: entry.state, exitCode: entry.exitCode, signal, endedAt: new Date().toISOString() }))
        .catch((err) => log('error', 'could not write DONE marker', { captureId, err: err.message }));
      log(entry.state === 'failed' ? 'error' : 'info', 'capture ended', { captureId, exitCode: entry.exitCode, signal });
      resolve();
    });
  });
  child.once('error', (err) => log('error', 'ffmpeg failed to start', { captureId, err: err.message }));
  let stderrBudget = 50; // ffmpeg can be chatty on packet loss: keep logs bounded
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => {
    if (stderrBudget-- > 0) log('warn', 'ffmpeg', { captureId, output: chunk.trim().slice(0, 500) });
  });

  captures.set(captureId, entry);
  entry.exited.then(() => setTimeout(() => captures.delete(captureId), 60_000).unref());
  log('info', 'capture started', { captureId, ports });
  return { captureId, dir, ports };
}

async function stopCapture(captureId) {
  const entry = captures.get(captureId);
  if (!entry) throw httpError(404, 'CAPTURE_NOT_FOUND', 'unknown capture');
  if (entry.state === 'running') {
    entry.state = 'stopping';
    entry.child.kill('SIGINT'); // ffmpeg closes the current segment cleanly and writes the list entry
    const killer = setTimeout(() => entry.child.kill('SIGKILL'), config.stopTimeoutMs);
    await entry.exited;
    clearTimeout(killer);
  } else {
    await entry.exited;
  }
  return describe(captureId, entry);
}

async function describe(captureId, entry) {
  let segments = 0;
  try {
    segments = (await readFile(join(entry.dir, 'segments.csv'), 'utf8')).split('\n').filter(Boolean).length;
  } catch {
    /* no segment closed yet */
  }
  return { captureId, state: entry.state, exitCode: entry.exitCode, segments, startedAt: new Date(entry.startedAt).toISOString() };
}

// ------------------------------------------------------------------ HTTP

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (req.method === 'GET' && url.pathname === '/healthz') {
      const scratchOk = await stat(config.scratch).then((s) => s.isDirectory(), () => false);
      return send(res, scratchOk && !shuttingDown ? 200 : 503, { ok: scratchOk && !shuttingDown, active: captures.size });
    }
    authorise(req);

    const match = /^\/captures(?:\/([A-Za-z0-9_-]{8,64}))?$/.exec(url.pathname);
    if (!match) throw httpError(404, 'NOT_FOUND', 'unknown path');
    const id = match[1];

    if (req.method === 'POST' && !id) {
      if (shuttingDown) throw httpError(503, 'SHUTTING_DOWN', 'capture agent is stopping');
      const body = JSON.parse((await readBody(req)) || '{}');
      if (!CAPTURE_ID.test(body.captureId ?? '')) throw badRequest('captureId must be 8-64 characters [A-Za-z0-9_-]');
      return send(res, 201, await startCapture(body.captureId, body.sdp));
    }
    if (req.method === 'GET' && id) {
      const entry = captures.get(id);
      if (!entry) throw httpError(404, 'CAPTURE_NOT_FOUND', 'unknown capture');
      return send(res, 200, await describe(id, entry));
    }
    if (req.method === 'DELETE' && id) return send(res, 200, await stopCapture(id));
    throw httpError(405, 'METHOD_NOT_ALLOWED', 'method not allowed');
  } catch (err) {
    const status = err.status ?? (err instanceof SyntaxError ? 400 : 500);
    if (status >= 500) log('error', 'request failed', { err: err.message });
    return send(res, status, { error: { code: err.code ?? (status === 400 ? 'BAD_JSON' : 'INTERNAL'), message: err.message } });
  }
});
server.requestTimeout = 30_000;

function authorise(req) {
  if (!config.token) return;
  const given = Buffer.from(String(req.headers.authorization ?? '').replace(/^Bearer /, ''));
  const expected = Buffer.from(config.token);
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) throw httpError(401, 'UNAUTHORISED', 'invalid token');
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_SDP_BYTES * 2) {
        reject(httpError(413, 'BODY_TOO_LARGE', 'body too large'));
        req.destroy();
      } else chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function send(res, status, body) {
  if (res.headersSent) return;
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify(body));
}

function httpError(status, code, message) {
  return Object.assign(new Error(message), { status, code });
}
function badRequest(message) {
  return httpError(400, 'BAD_SDP', message);
}
function int(value, fallback) {
  const n = Number.parseInt(value ?? '', 10);
  return Number.isFinite(n) ? n : fallback;
}

// ------------------------------------------------------------------ lifecycle

async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log('info', 'stopping capture agent', { signal, active: captures.size });
  // Finalise every running capture so its last segment is complete for the SFU to upload.
  await Promise.allSettled([...captures.keys()].map((id) => stopCapture(id)));
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2_000).unref();
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  if (config.rtpPortMin >= config.rtpPortMax) throw new Error('CAPTURE_RTP_PORT_MIN must be below CAPTURE_RTP_PORT_MAX');
  await mkdir(config.scratch, { recursive: true });
  server.listen(config.port, '127.0.0.1', () => log('info', 'capture agent listening', { port: config.port, scratch: config.scratch }));
}