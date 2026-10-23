import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/evidence_encryptor.dart';
import '../core/guardian_evidence_service.dart';
import '../core/mesh_service.dart';
import '../core/outbox_service.dart';
import '../logic/guardian_manager.dart';
import 'design/components.dart';
import 'design/tokens.dart';
import 'evidence_player_screen.dart';

/// Clips from people who chose this phone as a guardian. A clip opens only
/// once [EvidenceEncryptor.guardianQuorum] guardians' key pieces are here,
/// and only after it has been decrypted and verified.
class GuardianEvidenceScreen extends StatelessWidget {
  const GuardianEvidenceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Hive.box(MeshService.receivedSharesBoxName).listenable(),
      builder: (context, _, _) => ValueListenableBuilder(
        valueListenable: Hive.box(MeshService.relayBoxName).listenable(),
        builder: (context, _, _) {
          final incidents = GuardianEvidenceService.listIncidents();
          return SakPage(
            title: 'Guardian Evidence',
            slivers: [
              if (incidents.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: SakEmptyState(
                      icon: Icons.shield_rounded,
                      title: 'Nothing yet',
                      message: 'Clips and key pieces from people who added you as a '
                          'guardian appear here when your phones are near each other.',
                    ),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: incidents.length,
                  itemBuilder: (context, i) => Reveal(
                    index: i,
                    child: _IncidentTile(incident: incidents[i]),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _IncidentTile extends StatelessWidget {
  const _IncidentTile({required this.incident});
  final GuardianIncident incident;

  @override
  Widget build(BuildContext context) {
    final quorum = incident.threshold;
    final source = incident.hasLocalCopy
        ? 'copy on this phone'
        : incident.cid != null
            ? 'on IPFS'
            : 'clip not received yet';
    final when = incident.capturedAt?.toLocal().toString().substring(0, 16) ?? 'unknown time';

    final c = context.sak;
    final pieces = incident.shareCount.clamp(0, quorum);

    return Container(
      margin: const EdgeInsets.fromLTRB(SakSpace.lg, SakSpace.sm, SakSpace.lg, SakSpace.sm),
      padding: const EdgeInsets.all(SakSpace.lg),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(SakRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: c.accentSoft,
                child: Text(
                  incident.victimName.characters.first.toUpperCase(),
                  style: context.type.titleSmall?.copyWith(color: c.accent),
                ),
              ),
              const SizedBox(width: SakSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(incident.victimName, style: context.type.titleMedium),
                    Text('$when · $source', style: context.type.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: SakSpace.lg),
          // Key pieces as a row of slots: the clip opens when all are filled.
          Semantics(
            label: 'Key pieces ${incident.shareCount} of $quorum',
            child: ExcludeSemantics(
              child: Row(
                children: [
                  for (var i = 0; i < quorum; i++) ...[
                    if (i > 0) const SizedBox(width: SakSpace.xs),
                    Expanded(
                      child: AnimatedContainer(
                        duration: SakMotion.of(context, SakMotion.standard),
                        curve: SakMotion.spring,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i < pieces ? c.success : c.separator,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: SakSpace.md),
                  Text(
                    '${incident.shareCount} of $quorum keys',
                    style: context.type.labelMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: SakSpace.lg),
          SakButton(
            label: 'Open & Verify',
            icon: Icons.verified_user_rounded,
            onPressed: incident.hasQuorum ? () => _openAndVerify(context) : null,
          ),
          if (incident.hasOwnShare) ...[
            const SizedBox(height: SakSpace.sm),
            SakButton(
              label: 'Send My Piece',
              icon: Icons.key_rounded,
              style: SakButtonStyle.tinted,
              onPressed: () => _sendMyPiece(context),
            ),
          ],
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
            label: incident.victimName,
            loadPlaintext: () async => clip.plaintext,
            checks: clip.checks,
            anchorSummary: clip.anchorSummary,
          ),
        ),
      );
    } catch (e) {
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('Could not open clip: $e')));
    }
  }

  /// Hands this guardian's key piece to one co-guardian, with the user's
  /// explicit choice as the approval step.
  Future<void> _sendMyPiece(BuildContext context) async {
    final contacts = GuardianManager.getTrustedGuardians();
    final candidates = [
      for (final entry in contacts.entries)
        if (entry.key != incident.victimNodeId &&
            entry.value is Map &&
            entry.value['x25519_public_key'] != null)
          (nodeId: entry.key as String, name: entry.value['name'] as String? ?? entry.key as String),
    ];

    final messenger = ScaffoldMessenger.of(context);
    if (candidates.isEmpty) {
      messenger.showSnackBar(const SnackBar(
        content: Text("Pair with another of this person's guardians first."),
      ));
      return;
    }

    final chosen = await showDialog<({String nodeId, String name})>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text("Send your key piece for ${incident.victimName}'s clip to:"),
        children: [
          for (final c in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, c),
              child: Text(c.name),
            ),
        ],
      ),
    );
    if (chosen == null) return;

    await OutboxService.enqueueShareForward(incident.manifestHash, chosen.nodeId);
    await OutboxService.process();
    messenger.showSnackBar(SnackBar(
      content: Text('Will send to ${chosen.name} when your phones are near each other.'),
    ));
  }
}
