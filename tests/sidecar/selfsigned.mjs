// selfsigned.mjs — make a throwaway TLS certificate for the tests, in Node.
//
// The test of the sidecar's tunnel needs a TLS server that the sidecar will
// trust for a vendor's host name. Node can make a key pair but has no call
// that makes a certificate, and the tests use no outside tool and no
// dependency, so this file writes the certificate by hand: an X.509
// certificate is a handful of nested length-prefixed fields (DER), signed
// with the key.
//
// The certificate is self-signed, valid for two days around now, and names
// one host. The sidecar is told to trust it with NODE_EXTRA_CA_CERTS, a
// standard Node setting, so the sidecar's own certificate checking runs
// unchanged.

import crypto from 'node:crypto';

function length(n) {
  if (n < 0x80) return Buffer.from([n]);
  const bytes = [];
  for (let rest = n; rest > 0; rest >>= 8) bytes.unshift(rest & 0xff);
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}
const der = (tag, ...parts) => {
  const body = Buffer.concat(parts);
  return Buffer.concat([Buffer.from([tag]), length(body.length), body]);
};
const sequence = (...parts) => der(0x30, ...parts);
const set = (...parts) => der(0x31, ...parts);
const integer = (bytes) => der(0x02, bytes[0] & 0x80 ? Buffer.concat([Buffer.from([0]), bytes]) : bytes);
const boolTrue = der(0x01, Buffer.from([0xff]));
const octets = (bytes) => der(0x04, bytes);
const bits = (bytes) => der(0x03, Buffer.from([0]), bytes);
const utf8 = (text) => der(0x0c, Buffer.from(text, 'utf8'));
const time = (date) => der(0x17, Buffer.from(`${date.toISOString().replace(/[-:T]/g, '').slice(2, 14)}Z`, 'ascii'));
function oid(dotted) {
  const arcs = dotted.split('.').map(Number);
  const bytes = [40 * arcs[0] + arcs[1]];
  for (const arc of arcs.slice(2)) {
    const group = [arc & 0x7f];
    for (let rest = arc >> 7; rest > 0; rest >>= 7) group.unshift((rest & 0x7f) | 0x80);
    bytes.push(...group);
  }
  return der(0x06, Buffer.from(bytes));
}

// Returns { key, cert } as PEM text: a private key and a certificate for
// `hostName`, signed by that same key.
export function selfSigned(hostName) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const ecdsaWithSha256 = sequence(oid('1.2.840.10045.4.3.2'));
  const name = sequence(set(sequence(oid('2.5.4.3'), utf8(`sidecar test ${hostName}`))));
  const serial = crypto.randomBytes(8);
  serial[0] = (serial[0] & 0x7f) | 0x01;
  const day = 24 * 60 * 60 * 1000;
  const tbs = sequence(
    der(0xa0, integer(Buffer.from([2]))),                                     // version 3
    integer(serial),
    ecdsaWithSha256,
    name,                                                                     // issuer
    sequence(time(new Date(Date.now() - day)), time(new Date(Date.now() + day))),
    name,                                                                     // subject: the same, self-signed
    publicKey.export({ type: 'spki', format: 'der' }),
    der(0xa3, sequence(
      sequence(oid('2.5.29.17'), octets(sequence(der(0x82, Buffer.from(hostName, 'ascii'))))),   // the host name it is for
      sequence(oid('2.5.29.19'), boolTrue, octets(sequence(boolTrue))),                         // may act as its own authority
    )),
  );
  const certificate = sequence(tbs, ecdsaWithSha256, bits(crypto.sign('sha256', tbs, privateKey)));
  const pem = `-----BEGIN CERTIFICATE-----\n${certificate.toString('base64').match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----\n`;

  // Have Node read it back: a mistake above should fail here, not as a
  // puzzling handshake error later.
  const parsed = new crypto.X509Certificate(pem);
  if (!parsed.verify(publicKey) || !parsed.checkHost(hostName)) throw new Error('selfsigned: the certificate did not read back correctly');
  return { key: privateKey.export({ type: 'pkcs8', format: 'pem' }), cert: pem };
}
