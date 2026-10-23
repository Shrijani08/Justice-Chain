import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/evidence_encryptor.dart';
import '../core/recovery_service.dart';
import 'design/components.dart';
import 'design/tokens.dart';
import 'evidence_player_screen.dart';

/// Lists this device's own encrypted evidence records and lets the user
/// open one for playback. Only the self-wrapped key is used here — this is
/// the victim reviewing their own clips, not a guardian.
class EvidenceViewerScreen extends StatelessWidget {
  const EvidenceViewerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vaultBox = Hive.box('vault_box');

    // Evidence records carry a 'status' field; other box entries (like the
    // trusted-guardians map) don't, so this filters to evidence only.
    final entries = vaultBox
        .toMap()
        .entries
        .where((e) => e.value is Map && e.value['status'] != null)
        .toList()
      ..sort((a, b) {
        final aTime = a.value['timestamp'] as String? ?? '';
        final bTime = b.value['timestamp'] as String? ?? '';
        return bTime.compareTo(aTime);
      });

    return SakPage(
      title: 'My Evidence',
      slivers: [
        if (entries.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: SakEmptyState(
                icon: Icons.video_library_rounded,
                title: 'No evidence recorded yet',
                message: 'Recordings appear here, sealed and encrypted, the moment they stop.',
              ),
            ),
          )
        else
          SliverToBoxAdapter(
            child: SakGroup(
              header: entries.length == 1 ? '1 recording' : '${entries.length} recordings',
              footer: 'Each recording is named by its SHA-256 fingerprint. '
                  'Any change to the file would change it.',
              children: [
                for (final entry in entries) _EvidenceRow(entry: entry),
              ],
            ),
          ),
      ],
    );
  }
}

class _EvidenceRow extends StatelessWidget {
  const _EvidenceRow({required this.entry});
  final MapEntry<dynamic, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    final data = Map<String, dynamic>.from(entry.value as Map);
    final hash = data['hash'] as String? ?? entry.key.toString();
    final cipherPath = data['path'] as String?;
    final wrappedKey = data['wrappedKey'] as String?;
    final status = data['status'] as String? ?? 'unknown';
    final timestamp = data['timestamp'] as String? ?? '';
    // Restored from the ledger after a recovery: no local file;
    // fetched from IPFS and opened with the recovery code's key.
    final restored = status == RecoveryService.restoredStatus;
    final canPlay = restored || (cipherPath != null && wrappedKey != null);

    final (icon, color, label) = switch (status) {
      _ when restored => (Icons.restore_rounded, c.accent, 'Restored from ledger'),
      'anchored' => (Icons.verified_rounded, c.success, 'Anchored on ledger'),
      'uploaded_to_ipfs' => (Icons.cloud_done_rounded, c.success, 'Uploaded to IPFS'),
      'locally_secured' => (Icons.lock_rounded, c.warning, 'On this phone, upload pending'),
      _ => (Icons.lock_rounded, c.warning, status),
    };
    final when = DateTime.tryParse(timestamp)?.toLocal();
    final whenText = when == null
        ? timestamp
        : '${when.day.toString().padLeft(2, '0')}/${when.month.toString().padLeft(2, '0')}/${when.year} '
            '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';

    return Semantics(
      label: 'Recording $whenText, $label',
      child: SakRow(
        icon: icon,
        iconColor: color,
        enabled: canPlay,
        title: whenText.isEmpty ? 'Recording' : whenText,
        subtitle: label,
        trailing: MonoText(
          hash.length > 8 ? hash.substring(0, 8) : hash,
          style: context.type.labelSmall?.copyWith(color: c.inkTertiary),
        ),
        onTap: !canPlay
            ? null
            : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => EvidencePlayerScreen(
                      loadPlaintext: () => restored
                          ? RecoveryService.openRestoredClip(hash)
                          : EvidenceEncryptor.decryptFile(
                              cipherPath!,
                              wrappedKey!,
                            ),
                      label: hash.length > 12
                          ? hash.substring(0, 12)
                          : hash,
                    ),
                  ),
                );
              },
      ),
    );
  }
}
