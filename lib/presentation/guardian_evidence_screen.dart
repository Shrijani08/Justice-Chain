import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/authority_service.dart';
import '../core/co_guardian_service.dart';
import '../core/evidence_encryptor.dart';
import '../core/guardian_evidence_service.dart';
import '../core/mesh_service.dart';
import '../core/outbox_service.dart';
import '../logic/guardian_manager.dart';
import 'design/components.dart';
import 'pin_gate.dart';
import 'design/tokens.dart';
import 'evidence_player_screen.dart';
import 'evidence_viewer_screen.dart' show formatWhen;
import 'police_requests_screen.dart' show confirmPoliceRelease;

/// Clips from people who chose this phone as a guardian. A clip opens only
/// once [EvidenceEncryptor.guardianQuorum] guardians' key pieces are here,
/// and only after it has been decrypted and verified.
class GuardianEvidenceScreen extends StatefulWidget {
  const GuardianEvidenceScreen({super.key});

  @override
  State<GuardianEvidenceScreen> createState() => _GuardianEvidenceScreenState();
}

class _GuardianEvidenceScreenState extends State<GuardianEvidenceScreen> {
  /// Open police requests for clips this phone holds a piece of, by clip.
  Map<String, Map<String, dynamic>> _police = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Police requests, and key pieces co-guardians sent through the mailbox
  /// (stored pieces show up through the box listener).
  Future<void> _refresh() async {
    await Future.wait([
      _loadPolice(),
      CoGuardianService.fetchMailbox().catchError((Object _) => 0),
    ]);
  }

  Future<void> _loadPolice() async {
    if (!AuthorityService.available) return;
    try {
      final requests = await AuthorityService.openRequestsIGuard();
      if (mounted) setState(() => _police = {for (final r in requests) r['manifestHash'] as String: r});
    } catch (_) {
      // Offline: the cards show without requests; Police requests retries.
    }
  }

  @override
  Widget build(BuildContext context) {
    return PinGate(child: EmberScaffold(
      glows: const [
        Glow(color: Color(0xFF262B3D), width: 380, height: 320, opacity: 0.95, right: -120, top: -100),
        Glow(color: Ember.wineGlow, width: 260, height: 260, opacity: 0.7, left: -100, top: 380),
      ],
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: ValueListenableBuilder(
        valueListenable: Hive.box(MeshService.receivedSharesBoxName).listenable(),
        builder: (context, _, _) => ValueListenableBuilder(
          valueListenable: Hive.box(MeshService.relayBoxName).listenable(),
          builder: (context, _, _) {
            final incidents = GuardianEvidenceService.listIncidents();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SakTopBar(),
                const SizedBox(height: 16),
                const ScreenTitle('Guardian evidence', subtitle: 'Clips from people who chose you as a guardian'),
                const SizedBox(height: 16),
                Expanded(
                  child: incidents.isEmpty
                      ? const Center(
                          child: SakEmptyState(
                            icon: Icons.shield_outlined,
                            title: 'Nothing yet',
                            message: 'Clips and key pieces from people who added you as a guardian appear here when your phones are near each other.',
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 28),
                            itemCount: incidents.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 12),
                            itemBuilder: (context, i) => Reveal(
                              index: i,
                              child: _IncidentCard(incident: incidents[i], policeRequest: _police[incidents[i].manifestHash]),
                            ),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    ));
  }
}

class _IncidentCard extends StatelessWidget {
  const _IncidentCard({required this.incident, this.policeRequest});
  final GuardianIncident incident;

  /// An open police request for this clip, if there is one.
  final Map<String, dynamic>? policeRequest;

  @override
  Widget build(BuildContext context) {
    final quorum = incident.threshold;
    final source = incident.hasLocalCopy
        ? 'copy on this phone'
        : incident.cid != null
            ? 'on IPFS'
            : 'clip not received yet';
    final when = formatWhen(incident.capturedAt?.toLocal());
    final pieces = incident.shareCount.clamp(0, quorum);
    final ready = incident.hasQuorum;
    final tone = ready ? Ember.sealed : Ember.attention;

    return Glass(
      radius: SakRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Avatar(name: incident.victimName, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(incident.victimName, style: context.type.titleMedium),
                    const SizedBox(height: 2),
                    Text('$when · $source', style: context.type.bodySmall),
                  ],
                ),
              ),
              StatusPill(label: ready ? 'Ready' : 'Waiting', color: tone),
            ],
          ),
          const SizedBox(height: 14),
          // Key pieces as slots: the clip opens when all are filled.
          Semantics(
            label: 'Key pieces ${incident.shareCount} of $quorum',
            child: ExcludeSemantics(
              child: Row(
                children: [
                  for (var i = 0; i < quorum; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: AnimatedContainer(
                        duration: SakMotion.of(context, SakMotion.standard),
                        curve: SakMotion.spring,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i < pieces ? tone : const Color(0x1FFFFFFF),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  Text('${incident.shareCount} of $quorum keys', style: context.type.labelSmall?.copyWith(color: const Color(0xB3F4ECEE))),
                ],
              ),
            ),
          ),
          if (incident.forwardedFrom.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Piece received from ${incident.forwardedFrom.map(_guardianLabel).join(', ')}, '
              "on ${incident.victimName}'s guardian list.",
              style: context.type.bodySmall?.copyWith(color: Ember.sealed),
            ),
          ],
          if (!ready) ...[
            const SizedBox(height: 12),
            Text(
              AuthorityService.ledgerFeaturesEnabled
                  ? "Opens when another of ${incident.victimName}'s guardians sends you their piece."
                  : "Opens when another of ${incident.victimName}'s guardians shares their piece. Phones must be near each other.",
              style: context.type.bodySmall?.copyWith(color: const Color(0xB3F4ECEE)),
            ),
          ],
          if (policeRequest != null) ...[
            const SizedBox(height: 14),
            _PoliceRequestNotice(request: policeRequest!, owner: incident.victimName),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SakButton(
                  label: 'Open & verify',
                  icon: Icons.verified_user_outlined,
                  style: ready ? SakButtonStyle.pearl : SakButtonStyle.glass,
                  height: 50,
                  fontSize: 15,
                  onPressed: ready ? () => _openAndVerify(context) : null,
                ),
              ),
              if (incident.hasOwnShare) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: SakButton(
                    label: 'Send my piece',
                    icon: Icons.key_rounded,
                    style: SakButtonStyle.glass,
                    height: 50,
                    fontSize: 15,
                    onPressed: () => _sendMyPiece(context),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openAndVerify(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    showSakProgress(context, 'Decrypting and verifying…');

    try {
      final clip = await GuardianEvidenceService.openAndVerify(incident.manifestHash);
      navigator.pop();
      navigator.push(
        MaterialPageRoute(
          builder: (_) => EvidencePlayerScreen(
            title: incident.victimName,
            label: incident.manifestHash.length > 12 ? incident.manifestHash.substring(0, 12) : incident.manifestHash,
            loadPlaintext: () async => clip.plaintext,
            checks: clip.checks,
            summary: clip.summary,
          ),
        ),
      );
    } catch (e) {
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('Could not open clip: $e')));
    }
  }

  static String _guardianLabel(String nodeId) {
    final contact = GuardianManager.getAllContacts()[nodeId];
    final name = contact is Map ? contact['name'] as String? : null;
    return name ?? 'Guardian ${shortNodeId(nodeId)}';
  }

  /// Hands this guardian's key piece to one co-guardian, with the user's
  /// explicit choice as the approval step. On the Fabric ledger the
  /// co-guardians come from the victim's signed guardian list and the piece
  /// goes through the gateway's mailbox; otherwise only paired guardians
  /// nearby can receive it.
  Future<void> _sendMyPiece(BuildContext context) async {
    if (AuthorityService.ledgerFeaturesEnabled) return _sendViaLedger(context);
    final contacts = GuardianManager.getTrustedGuardians();
    final candidates = [
      for (final entry in contacts.entries)
        if (entry.key != incident.victimNodeId && entry.value is Map && entry.value['x25519_public_key'] != null)
          (nodeId: entry.key as String, name: entry.value['name'] as String? ?? entry.key as String),
    ];

    final messenger = ScaffoldMessenger.of(context);
    if (candidates.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text("Pair with another of this person's guardians first.")));
      return;
    }

    final chosen = await showSakSheet<({String nodeId, String name})>(
      context,
      (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Send your key piece', style: sheetContext.type.headlineSmall),
          const SizedBox(height: 6),
          Text("For ${incident.victimName}'s clip. Choose who gets it.", style: sheetContext.type.bodySmall),
          const SizedBox(height: 16),
          SakGroup(children: [
            for (final c in candidates)
              SakRow(
                leading: Avatar(name: c.name, size: 34),
                title: c.name,
                onTap: () => Navigator.pop(sheetContext, c),
              ),
          ]),
        ],
      ),
    );
    if (chosen == null) return;

    await OutboxService.enqueueShareForward(incident.manifestHash, chosen.nodeId);
    await OutboxService.process();
    messenger.showSnackBar(SnackBar(content: Text('Will send to ${chosen.name} when your phones are near each other.')));
  }

  Future<void> _sendViaLedger(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final victim = incident.victimName;

    showSakProgress(context, 'Checking the ledger…');
    final List<CoGuardian> coGuardians;
    try {
      coGuardians = await CoGuardianService.coGuardiansOf(incident.victimNodeId);
    } on UntrustedLedgerRecord catch (e) {
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text("Couldn't check $victim's guardians: ${e.message}.")));
      return;
    } catch (_) {
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't reach the ledger. Check the internet connection and try again.")));
      return;
    }
    navigator.pop();
    if (!context.mounted) return;
    if (coGuardians.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text('$victim has no other guardians on the ledger yet.')));
      return;
    }

    final chosen = await showSakSheet<CoGuardian>(
      context,
      (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Send your key piece', style: sheetContext.type.headlineSmall),
          const SizedBox(height: 6),
          Text("For $victim's clip. These are $victim's other guardians, from the list $victim signed on the ledger.",
              style: sheetContext.type.bodySmall),
          const SizedBox(height: 16),
          SakGroup(children: [
            for (final g in coGuardians)
              SakRow(
                leading: Avatar(name: g.name ?? 'G', size: 34),
                title: g.label,
                subtitle: g.name == null ? 'Not paired with you' : 'Paired with you',
                onTap: () => Navigator.pop(sheetContext, g),
              ),
          ]),
        ],
      ),
    );
    if (chosen == null || !context.mounted) return;

    if (!await confirmSak(
      context,
      title: 'Send your key piece to ${chosen.label}?',
      message: "With your piece and their own, ${chosen.label} can open $victim's clip.\n\n"
          'The piece is locked so only their phone can read it. The ledger records that you sent it, '
          "in the clip's audit trail. It can't be taken back.",
      confirmLabel: 'Send',
    )) {
      return;
    }
    // Sent right away rather than through the outbox, which runs one job at
    // a time and can sit behind older retries; the outbox is only the
    // fallback for when this attempt fails.
    if (!context.mounted) return;
    showSakProgress(context, 'Sending your piece…');
    try {
      final sent = await CoGuardianService.forwardViaMailbox(incident.manifestHash, chosen.nodeId);
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(sent
            ? 'Piece sent to ${chosen.label}. It reaches them the next time their app checks.'
            : "This phone doesn't hold its own piece of this clip, so there is nothing to send."),
      ));
    } catch (e) {
      navigator.pop();
      await OutboxService.enqueuePieceMailbox(incident.manifestHash, chosen.nodeId);
      unawaited(OutboxService.process());
      messenger.showSnackBar(SnackBar(content: Text("Couldn't send it yet ($e). The app will keep trying.")));
    }
  }
}

/// The police's request to open this clip, with the release button. Releasing
/// gives the police this guardian's piece; it does not give this phone theirs.
class _PoliceRequestNotice extends StatefulWidget {
  const _PoliceRequestNotice({required this.request, required this.owner});
  final Map<String, dynamic> request;
  final String owner;

  @override
  State<_PoliceRequestNotice> createState() => _PoliceRequestNoticeState();
}

class _PoliceRequestNoticeState extends State<_PoliceRequestNotice> {
  String get _id => widget.request['requestId'] as String;

  Future<void> _release() async {
    if (await confirmPoliceRelease(context, requestId: _id, own: false, owner: widget.owner) && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final started = AuthorityService.releaseStarted(_id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SakNotice(
          tone: started ? NoticeTone.sealed : NoticeTone.info,
          icon: Icons.local_police_outlined,
          title: started ? 'Released to the police' : 'The police asked to open this',
          message: started
              ? 'Your phone is sending your key piece to the Demo Police Authority (SIMULATED). It retries on its own if you are offline.'
              : 'Demo Police Authority (SIMULATED) · Case ${r['caseRef'] ?? '—'}\n“${r['reason'] ?? ''}”\n'
                  'If you do nothing, the police can’t open it.',
        ),
        if (!started) ...[
          const SizedBox(height: 10),
          SakButton(
            label: 'Release my key piece to police',
            icon: Icons.key_rounded,
            style: SakButtonStyle.pearl,
            height: 50,
            fontSize: 15,
            onPressed: _release,
          ),
        ],
      ],
    );
  }
}
