'use strict';

// The plain-words verification result shown above the portal's checks.
// Run: npm test

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { plainSummary, formatPlainDate, INTEGRITY_ONLY } = require('../summary');

const passed = [
  { name: 'Key pieces available', ok: true, detail: '' },
  { name: 'Hash matches the ledger record', ok: true, detail: '' },
  { name: 'Access recorded in the audit trail', ok: true, detail: '' },
];

test('all checks passed: what is proven, when, in which block, and what is not', () => {
  const s = plainSummary(passed, { capturedAt: '2026-10-27T14:33:00Z', blockNumber: 352 });
  assert.equal(s.tone, 'verified');
  assert.equal(s.headline, "This video has not been changed since the victim's phone sealed it on 27 Oct 2026, 20:03 IST.");
  assert.equal(s.notes[0], 'Its fingerprint has been on the ledger since block #352. All 3 checks passed, and this opening is recorded in the audit trail.');
  assert.equal(s.notes[1], INTEGRITY_ONLY);
});

test('a failed check says not to rely on the clip', () => {
  const s = plainSummary([...passed.slice(0, 1), { name: 'Hash matches the ledger record', ok: false, detail: 'x' }]);
  assert.equal(s.tone, 'failed');
  assert.equal(s.headline, "Don't rely on this clip: “Hash matches the ledger record” failed.");
  assert.ok(!s.notes.join(' ').includes('unchanged'));
});

test('a missing or bad time is left out rather than shown wrong', () => {
  assert.equal(formatPlainDate('not a date'), null);
  const s = plainSummary(passed, { capturedAt: 'not a date' });
  assert.equal(s.headline, "This video has not been changed since the victim's phone sealed it.");
  assert.equal(s.notes[0], 'All 3 checks passed, and this opening is recorded in the audit trail.');
});

test('the ledger stores capturedAt in Unix seconds, which must not read as 1970', () => {
  // 1793110380 s = 27 Oct 2026, 14:13 UTC (19:43 IST).
  assert.equal(formatPlainDate(1793110380), '27 Oct 2026, 19:43 IST');
  assert.equal(formatPlainDate('1793110380'), '27 Oct 2026, 19:43 IST');
  assert.equal(formatPlainDate(1793110380000), '27 Oct 2026, 19:43 IST');
});
