import 'guardian_evidence_service.dart' show VerificationCheck;

enum SummaryTone { verified, failed, unchecked }

/// What a clip's verification means, in words for someone who isn't
/// technical (a family member, a juror), shown above the technical checks.
class PlainSummary {
  const PlainSummary(this.tone, this.headline, this.notes);

  final SummaryTone tone;
  final String headline;
  final List<String> notes;

  /// Always said with a passing result: the checks prove the file is
  /// unchanged, not that the scene in it is real.
  static const integrityOnly = 'This proves the file is unchanged since it was sealed. '
      'It cannot prove that what the video shows is genuine.';

  /// A guardian's view of a clip from [owner]'s phone or SOS device.
  static PlainSummary ofChecks(
    List<VerificationCheck> checks, {
    required String owner,
    required bool fromSosDevice,
    DateTime? recordedAt,
    int? blockNumber,
  }) {
    final failed = checks.where((c) => c.passed == false).firstOrNull;
    if (failed != null) {
      return PlainSummary(SummaryTone.failed, "Don't rely on this clip: “${failed.label}” failed.", [
        "Something about this file doesn't match its sealed record. Keep it, but don't treat it as proof.",
      ]);
    }
    // Someone else anchoring first is reported, but her own record is still checked.
    final unchecked = checks.where((c) => c.passed == null && !c.label.startsWith('Anchored first')).firstOrNull;
    if (unchecked != null) {
      return PlainSummary(SummaryTone.unchecked, 'Not fully checked: “${unchecked.label}” could not be checked.', [
        'Nothing failed, but this check needs the internet. Try again when the phone is online.',
      ]);
    }
    final source = fromSosDevice ? "$owner's SOS device" : "$owner's phone";
    final when = recordedAt == null ? '' : ' on ${formatPlainDate(recordedAt)}';
    final passed = checks.where((c) => c.passed == true).length;
    return PlainSummary(SummaryTone.verified, 'This video has not been changed since $source sealed it$when.', [
      [
        if (blockNumber != null) 'Its fingerprint has been on the ledger since block #$blockNumber.',
        'All $passed checks passed.',
      ].join(' '),
      if (checks.any((c) => c.label.startsWith('Anchored first')))
        "Someone else also recorded this clip's fingerprint first; the owner's own record is still there and was checked.",
      integrityOnly,
    ]);
  }

  /// The owner's view of her own clip, which only opens if its fingerprint
  /// (and, for a device clip, the device's signature) matched.
  static PlainSummary ownClip({required bool fromSosDevice, DateTime? recordedAt}) {
    final source = fromSosDevice ? 'your SOS device' : 'your phone';
    final when = recordedAt == null ? '' : ' on ${formatPlainDate(recordedAt)}';
    return PlainSummary(SummaryTone.verified, 'This video has not been changed since $source sealed it$when.', const [
      'Its fingerprint matched when it opened.',
      integrityOnly,
    ]);
  }
}

/// "27 Oct 2026, 20:03" in the phone's time zone.
String formatPlainDate(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final local = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]} ${local.year}, ${two(local.hour)}:${two(local.minute)}';
}
