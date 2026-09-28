import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';
import { readFileSync } from 'node:fs';
import { createRelayGateway } from './relay-gateway.mjs';

// The fixtures and the upgrade client are raw sockets on purpose. `node:http`
// cannot answer or dial an upgrade under Bun (see relay-gateway.mjs), so
// building them on it would make this suite assert the runtime it is run under
// rather than the gateway — passing under Node while the shipped stack, which
// Aspire launches under Bun, is broken.
const tlsCert = process.env.TEST_TLS_CERT && readFileSync(process.env.TEST_TLS_CERT);
const tlsKey = process.env.TEST_TLS_KEY && readFileSync(process.env.TEST_TLS_KEY);
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));

// Answers one request per connection: a 101 plus a byte echo for an upgrade,
// the given body otherwise.
function upstream(body, options) {
  const sockets = new Set();
  const serve = socket => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    socket.on('error', () => socket.destroy());
    let head = '';
    socket.on('data', function collect(chunk) {
      head += chunk.toString('latin1');
      if (!head.includes('\r\n\r\n')) return;
      socket.removeListener('data', collect);
      if (/\r\nupgrade:/i.test(head)) {
        socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');
        socket.on('data', bytes => socket.write(bytes));
      } else {
        socket.end(`HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`);
      }
    });
  };
  const server = options ? tls.createServer(options, serve) : net.createServer(serve);
  return { server, close() { for (const socket of sockets) socket.destroy(); server.close(); } };
}

// Drives the upgrade end to end: raw request head in, 101 out, bytes echoed
// back through the splice.
function echo(connect, path) {
  return new Promise((resolve, reject) => {
    const socket = connect();
    const deadline = setTimeout(() => { socket.destroy(); reject(new Error('upgrade timeout')); }, 5000);
    let seen = '';
    socket.on('error', error => { clearTimeout(deadline); reject(error); });
    socket.on('data', chunk => {
      seen += chunk.toString('latin1');
      const end = seen.indexOf('\r\n\r\n');
      if (end < 0) return;
      if (!seen.startsWith('HTTP/1.1 101')) {
        clearTimeout(deadline);
        socket.destroy();
        reject(new Error(`not upgraded: ${seen.split('\r\n')[0]}`));
        return;
      }
      const body = seen.slice(end + 4);
      if (!body) { socket.write('opaque payload'); return; }
      clearTimeout(deadline);
      socket.destroy();
      resolve(body);
    });
    socket.on(socket.encrypted ? 'secureConnect' : 'connect', () => socket.write(
      `GET ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n`));
  });
}

test('cleartext mode routes both protocols over http and still denies private routes', async () => {
  // Dev-only shape: no certificate anywhere, so both hops are plain http and
  // there is nothing to verify rather than verification being relaxed.
  const central = upstream('central');
  const native = upstream('native');
  const centralPort = await listen(central.server), nativePort = await listen(native.server);
  const gateway = createRelayGateway({ hostname: '127.0.0.1', centralPort, nativePort, insecure: true });
  const port = await listen(gateway.server);
  function get(path) {
    return new Promise((resolve, reject) => {
      http.get({ hostname: '127.0.0.1', port, path }, response => {
        let body = '';
        response.on('data', chunk => body += chunk);
        response.on('end', () => resolve([response.statusCode, body]));
      }).on('error', reject);
    });
  }
  try {
    assert.deepEqual(await get('/health'), [200, 'central']);
    assert.deepEqual(await get('/ping'), [200, 'native']);
    assert.deepEqual(await get('/generate_204'), [200, 'native']);
    // The private admin and policy routes stay unreachable through the shared
    // origin whether or not TLS is on.
    assert.deepEqual(await get('/internal/disconnect'), [404, '']);
    assert.deepEqual(await get('/internal/peer-policy'), [404, '']);
    assert.equal(await echo(() => net.connect(port, '127.0.0.1'), '/ws'), 'opaque payload');
    assert.equal(await echo(() => net.connect(port, '127.0.0.1'), '/relay'), 'opaque payload');
  } finally {
    gateway.close();
    central.close();
    native.close();
  }
});

test('a spliced connection cannot carry a second request past the route check', async () => {
  // The route comes from the first head only, so the gateway has to make that
  // head the last one its socket carries.
  const central = upstream('central');
  const centralPort = await listen(central.server);
  const gateway = createRelayGateway({ hostname: '127.0.0.1', centralPort, nativePort: centralPort, insecure: true });
  const port = await listen(gateway.server);
  try {
    const replies = await new Promise((resolve, reject) => {
      const socket = net.connect(port, '127.0.0.1');
      let seen = '';
      const deadline = setTimeout(() => { socket.destroy(); resolve(seen); }, 3000);
      socket.on('error', reject);
      socket.on('data', chunk => seen += chunk.toString('latin1'));
      socket.on('close', () => { clearTimeout(deadline); resolve(seen); });
      socket.on('connect', () => socket.write(
        'GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n' +
        'GET /internal/disconnect HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'));
    });
    assert.equal(replies.split('HTTP/1.1').length - 1, 1, 'second pipelined request was answered');
    assert.match(replies, /^HTTP\/1\.1 200 /);
  } finally {
    gateway.close();
    central.close();
  }
});

test('shared TLS origin routes both protocols, denies private routes and verifies upstream TLS',
  { skip: tlsCert && tlsKey ? false : 'set TEST_TLS_CERT and TEST_TLS_KEY to run the TLS gate' }, async () => {
    const central = upstream('central');
    const native = upstream('native', { cert: tlsCert, key: tlsKey });
    const centralPort = await listen(central.server), nativePort = await listen(native.server);
    const gateway = createRelayGateway({
      cert: tlsCert, key: tlsKey, hostname: 'localhost', centralPort, nativePort, ca: tlsCert });
    const port = await listen(gateway.server);
    const options = { hostname: '127.0.0.1', servername: 'localhost', port, ca: tlsCert };
    function get(path, targetPort = port) {
      return new Promise((resolve, reject) => {
        https.get({ ...options, port: targetPort, path }, response => {
          let body = '';
          response.on('data', chunk => body += chunk);
          response.on('end', () => resolve([response.statusCode, body]));
        }).on('error', reject);
      });
    }
    const dial = () => tls.connect({ host: '127.0.0.1', port, servername: 'localhost', ca: tlsCert });
    let untrusted;
    try {
      assert.deepEqual(await get('/health'), [200, 'central']);
      assert.deepEqual(await get('/ping'), [200, 'native']);
      // With TLS on, the stock relay serves /generate_204 from a standalone
      // captive-portal listener on a different port, not https_bind_addr —
      // the gateway has no route for it in this mode (relay-gateway.mjs).
      assert.deepEqual(await get('/generate_204'), [404, '']);
      assert.deepEqual(await get('/internal/disconnect'), [404, '']);
      assert.deepEqual(await get('/internal/peer-policy'), [404, '']);
      assert.equal(await echo(dial, '/ws'), 'opaque payload');
      assert.equal(await echo(dial, '/relay'), 'opaque payload');
      // Without the CA the upstream certificate does not verify, and the route
      // fails closed rather than falling back to an unverified hop.
      untrusted = createRelayGateway({
        cert: tlsCert, key: tlsKey, hostname: 'localhost', centralPort, nativePort });
      assert.equal((await get('/ping', await listen(untrusted.server)))[0], 502);
    } finally {
      gateway.close();
      untrusted?.close();
      central.close();
      native.close();
    }
  });
