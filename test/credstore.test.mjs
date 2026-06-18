import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createCredStore, newAccountId } from '../src/credstore.mjs';

// Use a throwaway Keychain service so we never touch real credentials.
const SERVICE = 'claude-usage-dashboard-test-' + randomBytes(4).toString('hex');
const store = createCredStore(SERVICE);

const onMac = process.platform === 'darwin';
const opts = onMac ? {} : { skip: 'Keychain (security CLI) is macOS-only' };

after(async () => { if (onMac) await store._wipeAll().catch(() => {}); });

test('newAccountId is unique and prefixed', () => {
  assert.notEqual(newAccountId(), newAccountId());
  assert.match(newAccountId(), /^acct_/);
});

test('put / get / list / delete round-trip', opts, async () => {
  const a = { id: newAccountId(), label: 'a@x.com', accessToken: 'AT1', refreshToken: 'RT1', expiresAt: 111, tier: 'Max 20x' };
  const b = { id: newAccountId(), label: 'b@x.com', accessToken: 'AT2', refreshToken: 'RT2', expiresAt: 222, tier: 'Max 5x' };

  await store.putAccount(a);
  await store.putAccount(b);

  const got = await store.getAccount(a.id);
  assert.equal(got.accessToken, 'AT1');
  assert.equal(got.tier, 'Max 20x');

  const list = await store.listAccounts();
  assert.equal(list.length, 2);
  assert.deepEqual(list.map((x) => x.label).sort(), ['a@x.com', 'b@x.com']);

  // Update in place (same id) should not duplicate the index entry.
  await store.putAccount({ ...a, accessToken: 'AT1b' });
  const list2 = await store.listAccounts();
  assert.equal(list2.length, 2);
  assert.equal((await store.getAccount(a.id)).accessToken, 'AT1b');

  await store.deleteAccount(a.id);
  const list3 = await store.listAccounts();
  assert.equal(list3.length, 1);
  assert.equal(list3[0].id, b.id);
  assert.equal(await store.getAccount(a.id), null);
});

test('getAccount returns null for unknown id', opts, async () => {
  assert.equal(await store.getAccount('acct_nope'), null);
});
