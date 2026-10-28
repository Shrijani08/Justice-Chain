import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/guardian_evidence_service.dart';
import 'package:justice_chain/core/plain_summary.dart';

void main() {
  const passing = [
    VerificationCheck('Decrypted by guardian quorum', true, '2 key pieces'),
    VerificationCheck('Content hash matches', true, 'SHA-256 …'),
    VerificationCheck("Victim's device signature", true, 'Ed25519 key saved at pairing'),
    VerificationCheck('Anchored on-chain', true, 'anchored in block 352'),
  ];
  final recorded = DateTime(2026, 10, 27, 20, 3);

  test('all checks passed: says what is proven, and what is not', () {
    final s = PlainSummary.ofChecks(passing, owner: 'Sara', fromSosDevice: true, recordedAt: recorded, blockNumber: 352);
    expect(s.tone, SummaryTone.verified);
    expect(s.headline, "This video has not been changed since Sara's SOS device sealed it on 27 Oct 2026, 20:03.");
    expect(s.notes.first, 'Its fingerprint has been on the ledger since block #352. All 4 checks passed.');
    expect(s.notes.last, PlainSummary.integrityOnly);
  });

  test("a phone clip without a known time or block still reads as a sentence", () {
    final s = PlainSummary.ofChecks(passing, owner: 'Sara', fromSosDevice: false);
    expect(s.headline, "This video has not been changed since Sara's phone sealed it.");
    expect(s.notes.first, 'All 4 checks passed.');
  });

  test('a failed check says not to rely on the clip, whatever else passed', () {
    final s = PlainSummary.ofChecks([
      ...passing.take(2),
      const VerificationCheck("Victim's device signature", false, 'Signature does not verify'),
      const VerificationCheck('Anchored on-chain', null, 'Chain unreachable'),
    ], owner: 'Sara', fromSosDevice: false);
    expect(s.tone, SummaryTone.failed);
    expect(s.headline, "Don't rely on this clip: “Victim's device signature” failed.");
    expect(s.notes.join(), isNot(contains('unchanged')));
  });

  test('a check that could not run is not a pass', () {
    final s = PlainSummary.ofChecks([
      ...passing.take(3),
      const VerificationCheck('Anchored on-chain', null, 'Chain unreachable — could not check'),
    ], owner: 'Sara', fromSosDevice: false);
    expect(s.tone, SummaryTone.unchecked);
    expect(s.headline, 'Not fully checked: “Anchored on-chain” could not be checked.');
  });

  test('someone anchoring first is mentioned, but her own checked record still verifies', () {
    final s = PlainSummary.ofChecks([
      ...passing,
      const VerificationCheck('Anchored first by someone else', null, '0xabc anchored this clip first'),
    ], owner: 'Sara', fromSosDevice: false, blockNumber: 9);
    expect(s.tone, SummaryTone.verified);
    expect(s.notes, contains(startsWith('Someone else also recorded')));
  });

  test("the owner's own clip", () {
    final s = PlainSummary.ownClip(fromSosDevice: false, recordedAt: recorded);
    expect(s.tone, SummaryTone.verified);
    expect(s.headline, 'This video has not been changed since your phone sealed it on 27 Oct 2026, 20:03.');
    expect(s.notes, ['Its fingerprint matched when it opened.', PlainSummary.integrityOnly]);
  });
}
