// Forwards [::]:PORT to 127.0.0.1:TARGET.
//
// The Gateway resolves every bind mode to an IPv4 address, so it never listens
// on an IPv6 socket. Platforms whose private network is IPv6-only (Railway, for
// one) therefore cannot reach it at all, which forces a public ingress just to
// let a sibling service call the HTTP API. This forwarder removes that trade:
// the Gateway stays on loopback IPv4 and only this socket faces the private
// network.
//
// TCP only, no TLS, no auth — the Gateway still authenticates every request.
// Start it only on a trusted private network.

const net = require("net");

const listenPort = Number.parseInt(process.env.OPENCLAW_IPV6_PROXY_PORT ?? "", 10);
const targetPort = Number.parseInt(process.env.OPENCLAW_IPV6_PROXY_TARGET_PORT ?? "18789", 10);

if (!Number.isInteger(listenPort) || listenPort < 1 || listenPort > 65535) {
  console.error(`[ipv6-proxy] OPENCLAW_IPV6_PROXY_PORT must be a port number; got ${JSON.stringify(process.env.OPENCLAW_IPV6_PROXY_PORT)}`);
  process.exit(64);
}

const server = net.createServer((client) => {
  const upstream = net.connect({ host: "127.0.0.1", port: targetPort });
  // Either half closing tears down both, so a failed upstream never leaks a
  // half-open client socket.
  const drop = () => {
    client.destroy();
    upstream.destroy();
  };
  client.on("error", drop);
  upstream.on("error", drop);
  client.pipe(upstream);
  upstream.pipe(client);
});

server.on("error", (error) => {
  console.error(`[ipv6-proxy] listen failed: ${error.message}`);
  process.exit(70);
});

// "::" with ipv6Only unset accepts IPv4-mapped connections too, so one socket
// serves both families.
server.listen(listenPort, "::", () => {
  console.log(`[ipv6-proxy] listening on [::]:${listenPort} -> 127.0.0.1:${targetPort}`);
});
