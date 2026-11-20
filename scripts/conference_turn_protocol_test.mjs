// Protocol-level checks against a configured coturn. No credentials are printed or put in argv.
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {randomBytes, createHmac, createHash} from "node:crypto";
import {createSocket} from "node:dgram";
import {connect as tcpConnect} from "node:net";
import {connect as tlsConnect} from "node:tls";
import {resolve} from "node:path";

// Test endpoint metadata is separate from the app's ICE configuration.
// {host, port, tls_host, tls_port, ca_file, secret_file, min_port, max_port}
const config = JSON.parse(readFileSync(resolve(process.env.TURN_TEST_CONFIG)));
const secret = readFileSync(config.secret_file, "utf8").trim();
function attribute(type, value) {
  const head = Buffer.alloc(4); head.writeUInt16BE(type); head.writeUInt16BE(value.length, 2);
  return Buffer.concat([head, value, Buffer.alloc((4 - value.length % 4) % 4)]);
}
function request(type, attrs, auth) {
  const body = Buffer.concat(attrs);
  const head = Buffer.alloc(20); head.writeUInt16BE(type); head.writeUInt16BE(body.length + (auth ? 24 : 0), 2);
  head.writeUInt32BE(0x2112a442, 4); randomBytes(12).copy(head, 8);
  const message = Buffer.concat([head, body]);
  return auth ? Buffer.concat([message, attribute(0x0008, createHmac("sha1", auth).update(message).digest())]) : message;
}
function parse(buffer) {
  const attrs = new Map();
  for (let offset = 20; offset + 4 <= buffer.length;) {
    const type = buffer.readUInt16BE(offset), length = buffer.readUInt16BE(offset + 2);
    attrs.set(type, buffer.subarray(offset + 4, offset + 4 + length)); offset += 4 + Math.ceil(length / 4) * 4;
  }
  return {type: buffer.readUInt16BE(), attrs};
}
async function client(transport) {
  let socket;
  if (transport === "udp") socket = createSocket("udp4");
  else {
    socket = transport === "tls" ? tlsConnect({host: config.host, port: config.tls_port, servername: config.tls_host,
      ca: readFileSync(resolve(config.ca_file)), rejectUnauthorized: true}) : tcpConnect({host: config.host, port: config.port});
    await new Promise((ok, fail) => { socket.once(transport === "tls" ? "secureConnect" : "connect", ok); socket.once("error", fail); });
  }
  async function exchange(message) {
    return new Promise((ok, fail) => {
      let incoming = Buffer.alloc(0);
      const timer = setTimeout(() => finish(new Error(`${transport} response timeout`)), 4000);
      const event = transport === "udp" ? "message" : "data";
      function finish(error, result) { clearTimeout(timer); socket.off(event, receive); socket.off("error", failed); error ? fail(error) : ok(result); }
      function failed(error) { finish(error); }
      function receive(data) {
        incoming = Buffer.concat([incoming, data]);
        if (incoming.length >= 20 && incoming.length >= 20 + incoming.readUInt16BE(2)) {
          assert.deepEqual(incoming.subarray(8, 20), message.subarray(8, 20));
          finish(null, parse(incoming.subarray(0, 20 + incoming.readUInt16BE(2))));
        }
      }
      socket.on(event, receive); socket.once("error", failed);
      if (transport === "udp") socket.send(message, config.port, config.host); else socket.write(message);
    });
  }
  return {exchange, close: () => transport === "udp" ? socket.close() : socket.destroy()};
}
async function check(transport, kind = "valid") {
  const socket = await client(transport);
  try {
    const binding = await socket.exchange(request(1, []));
    assert.equal(binding.type, 0x0101);
    assert.ok(binding.attrs.has(0x0020));
    const requested = attribute(0x0019, Buffer.from([17, 0, 0, 0]));
    const challenge = await socket.exchange(request(3, [requested]));
    assert.equal(challenge.type, 0x0113); // unauthenticated allocation must fail
    assert.equal(challenge.attrs.get(9)[2] * 100 + challenge.attrs.get(9)[3], 401);
    const username = `${Math.floor(Date.now() / 1000) + (kind === "expired" ? -60 : 300)}:protocol-test`;
    const password = kind === "wrong-secret" ? "invalid-password" : createHmac("sha1", secret).update(username).digest("base64");
    const realm = challenge.attrs.get(0x0014), nonce = challenge.attrs.get(0x0015);
    const key = createHash("md5").update(`${username}:${realm.toString()}:${password}`).digest();
    const auth = [attribute(6, Buffer.from(username)), attribute(0x0014, realm), attribute(0x0015, nonce)];
    const allocation = await socket.exchange(request(3, [requested, ...auth], key));
    if (kind !== "valid") {
      assert.equal(allocation.type, 0x0113); assert.equal(allocation.attrs.has(0x0016), false);
      console.log(`PASS ${transport}: ${kind} credentials rejected`); return;
    }
    assert.equal(allocation.type, 0x0103);
    const relay = allocation.attrs.get(0x0016); assert.equal(relay[1], 1);
    const port = relay.readUInt16BE(2) ^ 0x2112;
    assert.ok(port >= config.min_port && port <= config.max_port);
    const cookie = Buffer.from([0x21, 0x12, 0xa4, 0x42]);
    const address = [...relay.subarray(4, 8)].map((byte, index) => byte ^ cookie[index]).join(".");
    assert.equal(address, config.host);
    const lifetime = Buffer.alloc(4);
    assert.equal((await socket.exchange(request(4, [attribute(0x000d, lifetime), ...auth], key))).type, 0x0104);
    console.log(`PASS ${transport}: anonymous allocation rejected; signed allocation ${address}:${port}; allocation released${transport === "tls" ? "; certificate verified against local CA" : ""}`);
  } finally { socket.close(); }
}
for (const transport of ["udp", "tcp", "tls"]) await check(transport);
await check("udp", "wrong-secret"); await check("udp", "expired");
