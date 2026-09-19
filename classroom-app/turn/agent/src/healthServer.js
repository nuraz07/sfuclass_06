// turn/agent/src/healthServer.js
//
// Small HTTP server of the agent, port TURN_AGENT_PORT (8080) on the host network:
//
//   GET  /healthz        200 while the self-probe passes (ECS container health check, node-lifecycle Lambda).
//                        503 otherwise; ECS replaces the task after the configured retries. A draining node stays
//                        healthy so ECS never kills it while allocations are still being served.
//   POST /drain          start draining (loopback only) — deploy-turn.yml via SSM
//   GET  /drain/status   {"draining": bool, "allocations": int, ...} (loopback only) — deploy-turn.yml via SSM
//
// Reachability: the security group of infra/modules/turn-node-pool opens this port to the VPC only;
// state-changing and drain routes additionally require a loopback peer address.
//
// Owner: F8 Real-Time Connectivity.

import http from 'node:http';

const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

/**
 * @param {object} options
 * @param {string} [options.host='0.0.0.0']
 * @param {number} [options.port=8080]
 * @param {() => { healthy: boolean, details: object }} options.getHealth
 * @param {import('./drain.js').DrainController} options.drain
 * @param {{ info: Function, warn: Function }} [options.logger]
 */
export function createHealthServer({ host = '0.0.0.0', port = 8080, getHealth, drain, logger = console }) {
  const server = http.createServer((req, res) => {
    const path = (req.url ?? '').split('?')[0];
    const send = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      res.end(JSON.stringify(body));
    };
    try {
      if (req.method === 'GET' && path === '/healthz') {
        const { healthy, details } = getHealth();
        return send(healthy ? 200 : 503, { status: healthy ? 'ok' : 'unhealthy', ...details });
      }
      const isDrainRoute = path === '/drain' || path === '/drain/status';
      if (isDrainRoute && !LOOPBACK.has(req.socket.remoteAddress)) {
        return send(403, { error: 'loopback only' });
      }
      if (req.method === 'POST' && path === '/drain') {
        const already = drain.isDraining();
        drain.begin({ reason: 'api' });
        logger.info({ already }, 'drain requested over HTTP');
        return send(202, drain.status());
      }
      if (req.method === 'GET' && path === '/drain/status') {
        const { draining, allocations, reason, since, completedAt, outcome } = drain.status();
        return send(200, { draining, allocations, reason, since, completedAt, outcome });
      }
      return send(404, { error: 'not found' });
    } catch (err) {
      logger.warn({ err: { message: err.message } }, 'health server request failed');
      return send(500, { error: 'internal' });
    }
  });
  server.requestTimeout = 5_000;
  server.headersTimeout = 5_000;

  return {
    listen: () => new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, host, () => {
        server.off('error', reject);
        resolve();
      });
    }),
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}