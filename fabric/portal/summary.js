'use strict';

// The officer portal's verification result in plain words, for someone who
// isn't technical (an officer, a judge, a juror). The same wording as the
// app's PlainSummary (lib/core/plain_summary.dart).

const INTEGRITY_ONLY = 'This proves the file is unchanged since it was sealed. '
  + 'It cannot prove that what the video shows is genuine.';

/**
 * "27 Oct 2026, 20:03" in India time. [value] is an ISO string or a Unix
 * time; the ledger stores capturedAt in seconds, which Date would read as
 * milliseconds (a 1970 date), so small numbers are taken as seconds.
 */
function formatPlainDate(value) {
  const n = typeof value === 'number' ? value
    : (typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : NaN);
  const t = Number.isNaN(n) ? new Date(value) : new Date(n < 1e12 ? n * 1000 : n);
  if (Number.isNaN(t.getTime())) return null;
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(t).map((p) => [p.type, p.value]));
  return `${parts.day} ${parts.month} ${parts.year}, ${parts.hour}:${parts.minute} IST`;
}

/**
 * [checks] as openClip reports them ({ name, ok, detail }); [record] the
 * ledger record when it was found. Returns { tone, headline, notes }.
 */
function plainSummary(checks, record) {
  const failed = (checks || []).find((c) => !c.ok);
  if (failed) {
    return {
      tone: 'failed',
      headline: `Don't rely on this clip: “${failed.name}” failed.`,
      notes: ["Something about this file doesn't match its sealed record. Keep it, but don't treat it as proof."],
    };
  }
  const when = record && formatPlainDate(record.capturedAt);
  return {
    tone: 'verified',
    headline: `This video has not been changed since the victim's phone sealed it${when ? ` on ${when}` : ''}.`,
    notes: [
      [
        record && record.blockNumber != null ? `Its fingerprint has been on the ledger since block #${record.blockNumber}.` : '',
        `All ${checks.length} checks passed, and this opening is recorded in the audit trail.`,
      ].filter(Boolean).join(' '),
      INTEGRITY_ONLY,
    ],
  };
}

module.exports = { plainSummary, formatPlainDate, INTEGRITY_ONLY };
