// Unit tests for the git relay's pkt-line reader and push filter [logical
// B30], with hand-made push bodies. No network, no git: `node --test`.

import assert from 'node:assert/strict';
import test from 'node:test';

import { CommandReader, judgePush, pkt, refusalReport } from '../../images/gitrelay/relay.mjs';

const BRANCH = 'agent/asb-demo-0a1b2c';
const REF = `refs/heads/${BRANCH}`;
const ZERO = '0'.repeat(40);
const OLD = 'a'.repeat(40);
const NEW = 'b'.repeat(40);
// What git 2.39 sends after the first ref line (note the leading space).
const CAPS = ' report-status-v2 side-band-64k object-format=sha1 agent=git/2.39.5';
const FLUSH = Buffer.from('0000');
const PACK = Buffer.from('PACK\0\0\0\x02 not a real pack, the relay never reads it', 'latin1');

// A push body: the first line carries the capabilities after a NUL byte.
function pushBody(commands, { caps = CAPS, pack = PACK } = {}) {
  const lines = commands.map((command, index) => pkt(index === 0 ? `${command}\0${caps}` : command));
  return Buffer.concat([...lines, FLUSH, pack]);
}

function read(body, chunkSize = body.length) {
  const reader = new CommandReader();
  for (let at = 0; at < body.length; at += chunkSize) {
    if (reader.push(body.subarray(at, at + chunkSize))) break;
  }
  reader.end();
  return reader;
}

function judge(body) {
  const reader = read(body);
  assert.equal(reader.error, '');
  return judgePush(reader.lines, BRANCH);
}

test('reader: stops at the flush packet and hands back the pack untouched', () => {
  const body = pushBody([`${OLD} ${NEW} ${REF}`]);
  const reader = read(body);
  assert.equal(reader.error, '');
  assert.equal(reader.done, true);
  assert.equal(reader.lines.length, 1);
  assert.deepEqual(Buffer.concat([reader.head, reader.rest]), body);
  assert.deepEqual(reader.rest, PACK);
});

test('reader: the same result whatever the chunk boundaries', () => {
  const body = pushBody([`${OLD} ${NEW} ${REF}`, `${OLD} ${NEW} refs/heads/main`]);
  for (const size of [1, 2, 3, 5, 7, 64, 150]) {
    const reader = new CommandReader();
    const after = [];
    for (let at = 0; at < body.length; at += size) {
      const chunk = body.subarray(at, at + size);
      if (reader.done) after.push(chunk);
      else reader.push(chunk);
    }
    assert.equal(reader.error, '', `chunk size ${size}`);
    assert.equal(reader.lines.length, 2, `chunk size ${size}`);
    assert.deepEqual(Buffer.concat([reader.head, reader.rest, ...after]), body, `chunk size ${size}`);
  }
});

test('reader: does not hold the pack', () => {
  const reader = new CommandReader();
  assert.equal(reader.push(pushBody([`${OLD} ${NEW} ${REF}`], { pack: Buffer.alloc(0) })), true);
  // Once done, further chunks are not taken in.
  assert.equal(reader.push(Buffer.alloc(1 << 20)), true);
  assert.equal(reader.rest.length, 0);
  assert.equal(reader.pending.length, 0);
});

test('reader: a truncated pkt-line is an error', () => {
  const whole = pushBody([`${OLD} ${NEW} ${REF}`]);
  for (const cut of [2, 4, 30, whole.length - PACK.length - 4, whole.length - PACK.length - 1]) {
    const reader = read(whole.subarray(0, cut));
    assert.match(reader.error, /ended before the end/, `cut at ${cut}`);
  }
});

test('reader: an oversized length is an error, before any of its bytes are awaited', () => {
  const reader = new CommandReader();
  assert.equal(reader.push(Buffer.from('ffff')), true);
  assert.match(reader.error, /longer than git allows/);
  // fff0 is git's ceiling and is accepted as a length.
  const atLimit = new CommandReader();
  assert.equal(atLimit.push(Buffer.from('fff0')), false);
  assert.equal(atLimit.error, '');
});

test('reader: too many ref lines is an error', () => {
  const reader = new CommandReader();
  const line = pkt(`${OLD} ${NEW} ${REF}`);
  let finished = false;
  for (let i = 0; i < 5000 && !finished; i += 1) finished = reader.push(line);
  assert.equal(finished, true);
  assert.match(reader.error, /too many ref lines/);
});

test('reader: lengths that are not four lowercase hex digits are errors', () => {
  for (const bad of ['00zz', '00A0', ' 0a0', 'PACK', '-001']) {
    assert.match(read(Buffer.from(`${bad}rest of it`)).error, /not four lowercase hex digits/, bad);
  }
});

test('reader: special and empty packets are errors', () => {
  assert.match(read(Buffer.from('0001')).error, /special packet/);
  assert.match(read(Buffer.from('0002')).error, /special packet/);
  assert.match(read(Buffer.from('00040000')).error, /empty pkt-line/);
});

test('filter: an update of the allowed branch is allowed', () => {
  const judged = judge(pushBody([`${OLD} ${NEW} ${REF}`]));
  assert.equal(judged.allow, true);
  assert.deepEqual(judged.commands, [{ old: OLD, new: NEW, ref: REF, reason: '' }]);
});

test('filter: creating the allowed branch is allowed', () => {
  assert.equal(judge(pushBody([`${ZERO} ${NEW} ${REF}`])).allow, true);
});

test('filter: sha-256 object ids are read too', () => {
  const judged = judge(pushBody([`${'a'.repeat(64)} ${'b'.repeat(64)} ${REF}`]));
  assert.equal(judged.allow, true);
  // ...but not one id of each length.
  assert.equal(judge(pushBody([`${OLD} ${'b'.repeat(64)} ${REF}`])).allow, false);
});

test('filter: a trailing newline on a line is accepted, as git accepts it', () => {
  const body = Buffer.concat([pkt(`${OLD} ${NEW} ${REF}\0${CAPS}\n`), FLUSH]);
  assert.equal(judge(body).allow, true);
});

test('filter: another branch is refused', () => {
  const judged = judge(pushBody([`${OLD} ${NEW} refs/heads/main`]));
  assert.equal(judged.allow, false);
  assert.match(judged.reason, /only refs\/heads\/agent\/asb-demo-0a1b2c may be pushed/);
});

test('filter: names that merely start with, or contain, the allowed ref are refused', () => {
  for (const ref of [`${REF}/sub`, `${REF}x`, `${REF}.`, `${REF}\n`, `${REF}\r`, `${REF}\t`, `${REF} `, ` ${REF}`,
    `refs/heads/${BRANCH.toUpperCase()}`, BRANCH, `refs/remotes/${BRANCH}`, `refs/heads/x/../${BRANCH}`, 'HEAD']) {
    const judged = judge(Buffer.concat([pkt(`${OLD} ${NEW} ${ref}\0${CAPS}`), FLUSH]));
    assert.equal(judged.allow, false, JSON.stringify(ref));
  }
});

test('filter: a tag is refused', () => {
  const judged = judge(pushBody([`${ZERO} ${NEW} refs/tags/v1.0`]));
  assert.equal(judged.allow, false);
  assert.match(judged.reason, /tags may not be pushed/);
});

test('filter: a delete is refused, of the allowed branch too', () => {
  const judged = judge(pushBody([`${OLD} ${ZERO} ${REF}`]));
  assert.equal(judged.allow, false);
  assert.match(judged.reason, /deleting a ref is not allowed/);
});

test('filter: two commands, one bad: the whole push is refused, whichever comes first', () => {
  for (const commands of [
    [`${OLD} ${NEW} ${REF}`, `${OLD} ${NEW} refs/heads/main`],
    [`${OLD} ${NEW} refs/heads/main`, `${OLD} ${NEW} ${REF}`],
  ]) {
    const judged = judge(pushBody(commands));
    assert.equal(judged.allow, false);
    assert.equal(judged.commands.length, 2);
    assert.ok(judged.commands.every((command) => command.reason !== ''), 'every ref gets a reason');
    assert.match(judged.commands.find((command) => command.ref === REF).reason, /another ref in the same push was refused/);
  }
});

test('filter: push options are refused', () => {
  const judged = judge(pushBody([`${OLD} ${NEW} ${REF}`], { caps: `${CAPS} push-options` }));
  assert.equal(judged.allow, false);
  assert.match(judged.reason, /push options are not allowed/);
});

test('filter: an unknown capability is refused', () => {
  const judged = judge(pushBody([`${OLD} ${NEW} ${REF}`], { caps: `${CAPS} something-new` }));
  assert.equal(judged.allow, false);
  assert.match(judged.reason, /capability the git relay does not allow/);
});

test('filter: capabilities smuggled onto a later line are refused', () => {
  const body = Buffer.concat([pkt(`${OLD} ${NEW} ${REF}\0${CAPS}`), pkt(`${OLD} ${NEW} ${REF}\0 push-options`), FLUSH]);
  const judged = judge(body);
  assert.equal(judged.allow, false);
  assert.match(judged.reason, /capabilities on a line other than the first/);
});

test('filter: shallow lines, push certificates and other lines are refused', () => {
  assert.match(judge(Buffer.concat([pkt(`shallow ${OLD}`), pkt(`${OLD} ${NEW} ${REF}\0${CAPS}`), FLUSH])).reason, /shallow clone/);
  assert.match(judge(Buffer.concat([pkt(`push-cert\0${CAPS}\n`), pkt('certificate version 0.1\n'), FLUSH])).reason, /signed pushes/);
  assert.match(judge(Buffer.concat([pkt('hello'), FLUSH])).reason, /not a ref update/);
  assert.match(judge(Buffer.concat([pkt(`${OLD}  ${NEW} ${REF}`), FLUSH])).reason, /not a ref update/);
  assert.match(judge(Buffer.concat([pkt(`${OLD.toUpperCase()} ${NEW} ${REF}`), FLUSH])).reason, /not a ref update/);
});

test('filter: a push with no ref lines (git\'s connection probe) is allowed and changes nothing', () => {
  const judged = judge(FLUSH);
  assert.equal(judged.allow, true);
  assert.deepEqual(judged.commands, []);
});

// Undo the side-band framing: collect what travelled on each channel.
function bands(buffer) {
  const out = { 1: [], 2: [], 3: [] };
  let at = 0;
  for (;;) {
    const length = parseInt(buffer.toString('latin1', at, at + 4), 16);
    if (length === 0) break;
    out[buffer[at + 4]].push(buffer.subarray(at + 5, at + length));
    at += length;
  }
  assert.equal(at + 4, buffer.length, 'nothing after the final flush packet');
  return { report: Buffer.concat(out[1]).toString('latin1'), note: Buffer.concat(out[2]).toString('utf8') };
}

test('refusal: reported to git ref by ref, inside the side band it asked for', () => {
  const judged = judge(pushBody([`${OLD} ${NEW} ${REF}`, `${ZERO} ${NEW} refs/tags/v1`]));
  const { report, note } = bands(refusalReport(judged, BRANCH));
  assert.match(note, /^git relay: push refused\. .*refs\/heads\/agent\/asb-demo-0a1b2c only/);
  const expected = Buffer.concat([
    pkt('unpack ok\n'),
    pkt(`ng ${REF} not pushed: another ref in the same push was refused\n`),
    pkt('ng refs/tags/v1 tags may not be pushed through the git relay\n'),
    FLUSH,
  ]).toString('latin1');
  assert.equal(report, expected);
});

test('refusal: plain report without a side band; none when the client asked for no report', () => {
  const plain = judge(pushBody([`${OLD} ${NEW} refs/heads/main`], { caps: ' report-status' }));
  assert.match(refusalReport(plain, BRANCH).toString('latin1'), /^000eunpack ok\n[0-9a-f]{4}ng refs\/heads\/main only /);
  const silent = judge(pushBody([`${OLD} ${NEW} refs/heads/main`], { caps: ' quiet' }));
  assert.equal(refusalReport(silent, BRANCH), null);
  const unreadable = judge(Buffer.concat([pkt('hello'), FLUSH]));
  assert.equal(refusalReport(unreadable, BRANCH), null);
});
