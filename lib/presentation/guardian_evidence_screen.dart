import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/evidence_encryptor.dart';
import '../core/guardian_evidence_service.dart';
import '../core/mesh_service.dart';
import '../core/outbox_service.dart';
import '../logic/guardian_manager.dart';
import 'evidence_player_screen.dart';

/// Clips from people who chose this phone as a guardian. A clip opens only
/// once [EvidenceEncryptor.guardianQuorum] guardians' key pieces are here,
/// and only after it has been decrypted and verified.
class GuardianEvidenceScreen extends StatelessWidget {
  const GuardianEvidenceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Guardian Evidence')),
      body: ValueListenableBuilder(
        valueListenable: Hive.box(MeshService.receivedSharesBoxName).listenable(),
        builder: (context, _, _) => ValueListenableBuilder(
          valueListenable: Hive.box(MeshService.relayBoxName).listenable(),
          builder: (context, _, _) {
            final incidents = GuardianEvidenceService.listIncidents();
            if (incidents.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Nothing yet. Clips and key pieces from people who added you as a '
                    'guardian appear here when your phones are near each other.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView.separated(
              itemCount: incidents.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _IncidentTile(incident: incidents[i]),
            );
          },
        ),
      ),
    );
  }
}

class _IncidentTile extends StatelessWidget {
  const _IncidentTile({required this.incident});
  final GuardianIncident incident;

  @override
  Widget build(BuildContext context) {
    final quorum = EvidenceEncryptor.guardianQuorum;
    final source = incident.hasLocalCopy
        ? 'copy on this phone'
        : incident.cid != null
            ? 'on IPFS'
            : 'clip not received yet';
    final when = incident.capturedAt?.toLocal().toString().substring(0, 16) ?? 'unknown time';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(incident.victimName, style: Theme.of(context).textTheme.titleMedium),
          Text('$when · key pieces ${incident.shareCount}/$quorum · $source'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: incident.hasQuorum ? () => _openAndVerify(context) : null,
                icon: const Icon(Icons.verified_user),
                label: const Text('Open & verify'),
              ),
              if (incident.hasOwnShare)
                OutlinedButton.icon(
                  onPressed: () => _sendMyPiece(context),
                  icon: const Icon(Icons.key),
                  label: const Text('Send my piece'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openAndVerify(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Decrypting and verifying…')),
          ],
        ),
      ),
    );

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
