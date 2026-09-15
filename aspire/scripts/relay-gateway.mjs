import net from 'node:net';
import tls from 'node:tls';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

// Payloads remain opaque: only the request head is parsed, to pick a route, and
// every byte after it is spliced through untouched. Authentication and
// authorization stay in their owning relay services.
//
// Splicing rather than re-issuing the request through an HTTP client is what
// makes this work on both runtimes the apphost may launch it under. `node:http`
// cannot proxy an upgrade under Bun in either direction: a write to the socket
// handed to a server 'upgrade' event is discarded, and a client request never
// emits 'upgrade' for a 101, delivering it as an ordinary response instead.
// Raw sockets have neither problem, so nothing here depends on which of Node or
// Bun is `process.execPath`.
//
// `insecure` drops TLS on both hops, for a local stack with no certificate. It
// is not a relaxation of verification: with TLS off there is no certificate to
// verify, so the flag must never be used to paper over one that fails.

const HEAD_LIMIT = 8192;
const HEAD_TIMEOUT = 10_000;
const UPSTREAM_TIMEOUT = 10_000;
const CENTRAL_ROUTES = ['/ws', '/health'];
const NATIVE_ROUTES = ['/relay', '/ping', '/generate_204'];

function respond(socket, status) {
  socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
}

// Reads until the end of the request head, then hands it over with whatever
// bytes already arrived behind it. The socket is paused first so nothing is
// dropped in the gap before it is spliced onto the upstream.
function readHead(socket, ready) {
  let buffer = Buffer.alloc(0);
  const timer = setTimeout(() => socket.destroy(), HEAD_TIMEOUT);
  socket.on('close', () => clearTimeout(timer));
  socket.on('data', function collect(chunk) {
    buffer = Buffer.concat([buffer, chunk]);
    const end = buffer.indexOf('\r\n\r\n');
    if (end < 0) {
      if (buffer.length > HEAD_LIMIT) { clearTimeout(timer); socket.destroy(); }
      return;
    }
    clearTimeout(timer);
    socket.pause();
    socket.removeListener('data', collect);
    if (end + 4 > HEAD_LIMIT) { socket.destroy(); return; }
    ready(buffer.toString('latin1', 0, end + 4), buffer.subarray(end + 4));
  });
}

export function createRelayGateway({ cert, key, hostname, centralPort = 3001, nativePort = 443, ca, insecure = false }) {
  const sockets = new Set();

  function target(path) {
    if (CENTRAL_ROUTES.includes(path)) return { port: centralPort, secure: false };
    if (NATIVE_ROUTES.includes(path)) return { port: nativePort, secure: !insecure };
    return null;
  }

  function rewrite(head, upgrade) {
    const [requestLine, ...lines] = head.split('\r\n').filter(Boolean);
    const headers = lines.filter(line => {
      const name = line.slice(0, line.indexOf(':')).trim().toLowerCase();
      // Do not forward claimed client IPs as trusted proxy identity.
      if (name === 'x-forwarded-for' || name === 'forwarded') return false;
      return upgrade || name !== 'connection';
    });
    // A spliced connection is pinned to the route its first head chose, so a
    // plain request must be the only one on its socket — otherwise a second
    // request could reach a route the gateway never checked it against.
    if (!upgrade) headers.push('Connection: close');
    return [requestLine, ...headers, '', ''].join('\r\n');
  }

  function accept(socket) {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    socket.on('error', () => socket.destroy());
    readHead(socket, (head, rest) => {
      const path = head.split('\r\n')[0].split(' ')[1]?.split('?')[0] ?? '';
      const destination = target(path);
      if (!destination) { respond(socket, '404 Not Found'); return; }
      const upgrade = /\r\nupgrade:/i.test(head);
      const peer = destination.secure
        ? tls.connect({ host: '127.0.0.1', port: destination.port, servername: hostname, ca })
        : net.connect({ host: '127.0.0.1', port: destination.port });
      let answered = false;
      const timer = setTimeout(() => peer.destroy(), UPSTREAM_TIMEOUT);
      peer.once('data', () => { answered = true; clearTimeout(timer); });
      peer.on('error', () => {
        clearTimeout(timer);
        if (answered || upgrade) socket.destroy(); else respond(socket, '502 Bad Gateway');
      });
      socket.on('close', () => { clearTimeout(timer); peer.destroy(); });
      // `pipe` already ends this side when the upstream ends, so destroying on
      // close would cut a response still draining out of the buffer.
      peer.on('close', () => { if (!socket.writableEnded) socket.destroy(); });
      peer.on(destination.secure ? 'secureConnect' : 'connect', () => {
        peer.write(rewrite(head, upgrade));
        if (rest.length) peer.write(rest);
        socket.pipe(peer);
        peer.pipe(socket);
      });
    });
  }

  const server = insecure
    ? net.createServer(accept)
    : tls.createServer({ cert, key }, accept);
  server.maxConnections = 256;
  return { server, close() { for (const socket of sockets) socket.destroy(); server.close(); } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const insecure = process.env.ANTGRID_DEV_INSECURE_RELAY === 'true';
  const gateway = createRelayGateway({
    ...(insecure ? {} : {
      cert: readFileSync(process.env.ANTGRID_RELAY_TLS_CERT),
      key: readFileSync(process.env.ANTGRID_RELAY_TLS_KEY),
    }),
    hostname: process.env.ANTGRID_RELAY_HOST,
    nativePort: Number(process.env.ANTGRID_RELAY_NATIVE_PORT ?? 443),
    insecure,
  });
  gateway.server.listen(3000, '0.0.0.0', () => console.log(
    `[relay-gateway] ${insecure ? 'HTTP (cleartext, dev only)' : 'HTTPS'} :3000; /ws -> central, /relay -> Iroh`));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => gateway.close());
}
