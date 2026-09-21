import { io } from 'socket.io-client';

const origin = 'https://localhost:5173'; // what Codespaces sends as Origin
for (const base of ['http://localhost:4000', 'http://localhost:5173']) {
  await new Promise((done) => {
    const socket = io(`${base}/classroom`, {
      transports: ['websocket'],
      auth: { token: 'not-a-real-token' },
      extraHeaders: { Origin: origin },
      reconnection: false,
      timeout: 5000,
    });
    const finish = (msg) => { console.log(`${base.padEnd(24)} -> ${msg}`); socket.close(); done(); };
    socket.on('connect', () => finish('CONNECTED (auth was not checked)'));
    socket.on('connect_error', (e) => finish(`connect_error: ${e.message}${e.description?.message ? ' / ' + e.description.message : ''}${e.data ? ' / ' + JSON.stringify(e.data) : ''}`));
    setTimeout(() => finish('TIMEOUT: no answer within 6 s'), 6000);
  });
}
process.exit(0);
