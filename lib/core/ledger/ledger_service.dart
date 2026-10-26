/// A ledger anchor as read back for verification.
class AnchorVerificationResult {
  const AnchorVerificationResult({
    required this.found,
    required this.cid,
    required this.capturedAt,
    required this.anchoredAt,
    required this.nodeId,
    required this.signer,
    this.anchoredAtIsLedgerTime = true,
    this.blockNumber,
    this.claims = const [],
  });

  final bool found;
  final String cid;

  /// The capturing device's own clock.
  final DateTime capturedAt;

  /// When the anchor was recorded. On the EVM this is the block's own
  /// timestamp; on Fabric it is the gateway's clock (Fabric takes the
  /// transaction time from the submitting client), so it must not be shown
  /// as ledger time. [anchoredAtIsLedgerTime] says which.
  final DateTime anchoredAt;
  final bool anchoredAtIsLedgerTime;

  final String nodeId;

  /// Address the device signature recovers to, 0x-prefixed.
  final String signer;

  /// The block this anchor committed in, when the ledger reports it.
  final int? blockNumber;

  /// Later anchors of the same clip by other signers (Fabric chaincode
  /// 1.7). Whoever anchors a clip first holds the record, so a clip's own
  /// device may be one of these if, say, a relaying guardian anchored first.
  final List<AnchorVerificationResult> claims;

  /// The anchor signed by [address]: this record or one of its claims.
  AnchorVerificationResult? bySigner(String address) {
    final wanted = address.toLowerCase();
    for (final anchor in [this, ...claims]) {
      if (anchor.found && anchor.signer.toLowerCase() == wanted) return anchor;
    }
    return null;
  }
}

/// The block an anchor was committed in. Fabric blocks carry no timestamp,
/// so [blockTime] is null there.
typedef AnchorBlock = ({int blockNumber, DateTime? blockTime});

/// One ledger the app can anchor evidence on. Implementations throw on any
/// failure (unreachable, misconfigured, or the ledger refusing the
/// transaction); AnchoringService turns that into a logged null, so
/// anchoring stays additive proof that never blocks an upload.
abstract class LedgerService {
  /// Human-readable name for logs, e.g. "Hardhat (EVM)".
  String get name;

  /// Submits an anchor carrying the device's [signatureHex] (65-byte
  /// EIP-191 signature over the manifest hash). Returns the transaction ID.
  Future<String> recordAnchor({
    required String manifestHashHex,
    required String cid,
    required DateTime capturedAt,
    required String nodeId,
    required String signatureHex,
  });

  /// The anchor for [manifestHashHex]; found is false if there is none.
  Future<AnchorVerificationResult> verifyEvidence(String manifestHashHex);

  /// The block holding [manifestHashHex]'s anchor, or null if none.
  Future<AnchorBlock?> findAnchorBlock(String manifestHashHex);

  /// Every manifest hash anchored under [nodeId], in anchoring order.
  Future<List<String>> getEvidenceHistory(String nodeId);
}
