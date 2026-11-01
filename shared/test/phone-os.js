// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
// P.isPhoneOs: an iPhone/iPad (os 'ios') is a phone-class peer like an Android phone, and the Remote
// page's input (shared/phone-remote.js) is taken from it; a computer's is not.
'use strict';

const assert = require('assert');
const { EventEmitter } = require('events');
const P = require('../protocol.js');
const { PhoneRemote } = require('../phone-remote.js');

assert.strictEqual(P.OS.IOS, 'ios');
assert.ok(Object.values(P.OS).includes('ios'), 'ios is a known os (pairing no longer files it under win)');
assert.strictEqual(P.isPhoneOs('android'), true);
assert.strictEqual(P.isPhoneOs('ios'), true);
for (const os of ['mac', 'win', 'linux', '', undefined, null]) assert.strictEqual(P.isPhoneOs(os), false, String(os));

function remote(os) {
  const sent = [];
  const injected = [];
  const server = Object.assign(new EventEmitter(), { current: { os }, sendToClient: (m) => sent.push(m) });
  const r = new PhoneRemote({
    server,
    helper: { send: (k, v) => injected.push([k, v]), request: async () => ({ type: true }) },
    getSettings: () => ({ remote: { allow: true } }),
    atHome: () => true,
  });
  return { server, sent, injected, r };
}

(async () => {
  for (const os of ['android', 'ios']) {
    const { server, sent, injected } = remote(os);
    server.emit('t:remote.hello', {});
    assert.strictEqual(sent[0].t, 'remote.state', os);
    assert.strictEqual(sent[0].allowed, true, os);
    server.emit('t:remote.mm', { dx: 5, dy: -3 });
    assert.deepStrictEqual(injected[0], ['inject', { ev: { t: 'k.mm', dx: 5, dy: -3, smooth: false } }], os);
  }

  // A computer's remote.* is ignored.
  const win = remote('win');
  win.server.emit('t:remote.hello', {});
  win.server.emit('t:remote.mm', { dx: 1, dy: 1 });
  assert.strictEqual(win.sent.length, 0);
  assert.strictEqual(win.injected.length, 0);

  console.log('ok');
})().catch((e) => { console.error(e); process.exit(1); });
