import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseTailscaleIp, loadConfig } from '../src/config.mjs';

test('parseTailscaleIp takes only a real dotted quad, preferring the CGNAT range', () => {
  assert.equal(parseTailscaleIp('100.126.121.49\n'), '100.126.121.49');
  assert.equal(parseTailscaleIp('  100.106.66.72  \n'), '100.106.66.72');
  assert.equal(parseTailscaleIp('192.168.1.5\n100.64.0.9\n'), '100.64.0.9');
  assert.equal(parseTailscaleIp('192.168.1.5\n'), '192.168.1.5');
  // The CLI's failure sentence on stdout must never become a bind host.
  assert.equal(parseTailscaleIp('The Tailscale GUI failed to start: The operation couldn’t be completed. (Tailscale.CLIError error 3.)\n'), null);
  assert.equal(parseTailscaleIp(''), null);
  assert.equal(parseTailscaleIp(null), null);
});

test('CLAUDE_USAGE_BIND overrides detection', () => {
  const cfg = loadConfig({ CLAUDE_USAGE_BIND: '127.0.0.1', CLAUDE_USAGE_PORT: '4444' });
  assert.equal(cfg.bindHost, '127.0.0.1');
  assert.equal(cfg.port, 4444);
});
