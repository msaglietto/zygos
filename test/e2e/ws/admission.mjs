// Real loopback handshake and delivery checks; Node stdlib only, no SDK install.
import assert from 'node:assert/strict';
import net from 'node:net';
import { randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

async function connect(port) {
  const socket = net.createConnection({ host: '127.0.0.1', port });
  await once(socket, 'connect').catch((err) => { socket.destroy(); throw err; });
  return socket;
}

function ping() {
  const payload = Buffer.from('{"type":"ping"}');
  const mask = randomBytes(4);
  const frame = Buffer.alloc(6 + payload.length);
  frame[0] = 0x81;
  frame[1] = 0x80 | payload.length;
  mask.copy(frame, 2);
  for (let i = 0; i < payload.length; i++) frame[6 + i] = payload[i] ^ mask[i % 4];
  return frame;
}

async function handshake(port, target = '/', origin, churn = false) {
  const socket = await connect(port);
  let bytes = Buffer.alloc(0);
  const result = new Promise((resolve, reject) => {
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('handshake deadline')); }, 2500);
    socket.on('data', (data) => {
      bytes = Buffer.concat([bytes, data]);
      if (bytes.includes(Buffer.from('workerregistered'))) {
        if (churn) for (let i = 0; i < 16; i++) socket.write(ping());
        clearTimeout(timer);
        socket.destroy();
        resolve(true);
      }
    });
    socket.on('error', () => {}); // admission refusal may reset the connection
    socket.on('close', () => { clearTimeout(timer); resolve(false); });
  });
  const headers = [
    `GET ${target} HTTP/1.1`, `Host: 127.0.0.1:${port}`,
    'Upgrade: websocket', 'Connection: Upgrade', 'Sec-WebSocket-Version: 13',
    `Sec-WebSocket-Key: ${randomBytes(16).toString('base64')}`,
  ];
  if (origin !== undefined) headers.push(`Origin: ${origin}`);
  socket.write(headers.join('\r\n') + '\r\n\r\n');
  return result;
}

const home = await mkdtemp(join(tmpdir(), 'zygos-ws-fixture-'));
try {
  for (const secured of [false, true]) {
    const reservation = net.createServer();
    reservation.listen(0, '127.0.0.1');
    await once(reservation, 'listening');
    const port = reservation.address().port;
    await new Promise((resolve) => reservation.close(resolve));
    const env = { PATH: process.env.PATH, HOME: home, ZYGOS_PORT: String(port) };
    if (secured) {
      env.ZYGOS_TOKEN = 'fixture-token';
      env.ZYGOS_ALLOW_ORIGIN = 'https://allowed.example';
    }
    const child = spawn('./zig-out/bin/zygos', [], { env, stdio: ['ignore', 'ignore', 'ignore'] });
    const exited = once(child, 'exit');
    try {
      let ready = false;
      for (let i = 0; i < 100 && child.exitCode === null; i++) {
        try { const socket = await connect(port); socket.destroy(); ready = true; break; }
        catch { await delay(20); }
      }
      assert.ok(ready, 'kernel must listen');
      const target = secured ? '/?token=fixture-token' : '/';
      assert.equal(await handshake(port, target), true, 'script client admitted');
      assert.equal(await handshake(port, target, 'https://evil.example'), false, 'foreign browser refused');
      if (secured) {
        assert.equal(await handshake(port, '/'), false, 'missing token refused');
        assert.equal(await handshake(port, '/?token=wrong'), false, 'wrong token refused');
        assert.equal(await handshake(port, target, 'https://allowed.example'), true, 'explicit Origin allowed');
      }
      for (let i = 0; i < 32; i++) assert.equal(await handshake(port, target, undefined, true), true);
      assert.equal(await handshake(port, target), true, 'kernel survives reply/disconnect churn');
    } finally {
      child.kill('SIGTERM');
      await exited;
    }
  }
} finally {
  await rm(home, { recursive: true, force: true });
}
console.log('WS E2E OK: Origin/token admission and reply/disconnect churn');
