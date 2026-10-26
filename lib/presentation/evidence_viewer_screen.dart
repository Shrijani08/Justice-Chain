import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/evidence_vault_service.dart';
import '../core/recovery_service.dart';
import 'design/components.dart';
import 'pin_gate.dart';
import 'design/tokens.dart';
import 'evidence_player_screen.dart';

/// Lists this device's own encrypted evidence records and lets the user
/// open one for playback. Only the self-wrapped key is used here — this is
/// the victim reviewing their own clips, not a guardian.
class EvidenceViewerScreen extends StatefulWidget {
  const EvidenceViewerScreen({super.key});

  @override
  State<EvidenceViewerScreen> createState() => _EvidenceViewerScreenState();
}

enum _Filter { all, ledger, pending }

class _EvidenceViewerScreenState extends State<EvidenceViewerScreen> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    return PinGate(child: EmberScaffold(
      glows: const [
        Glow(color: Color(0xFF3A1F55), width: 380, height: 320, opacity: 0.9, left: -100, top: -100),
        Glow(color: Ember.wineGlow, width: 260, height: 260, opacity: 0.7, right: -100, top: 360),
      ],
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: ValueListenableBuilder(
        valueListenable: Hive.box('vault_box').listenable(),
        builder: (context, box, _) {
          // Evidence records carry a 'status' field; other box entries (like
          // the trusted-guardians map) don't, so this filters to evidence only.
          final all = box
              .toMap()
              .entries
              .where((e) => e.value is Map && e.value['status'] != null)
              .toList()
            ..sort((a, b) {
              final aTime = a.value['timestamp'] as String? ?? '';
              final bTime = b.value['timestamp'] as String? ?? '';
              return bTime.compareTo(aTime);
            });
          final shown = all.where((e) {
            final status = e.value['status'];
            return switch (_filter) {
              _Filter.all => true,
              _Filter.ledger => status == 'anchored' || status == RecoveryService.restoredStatus,
              _Filter.pending => status != 'anchored' && status != RecoveryService.restoredStatus,
            };
          }).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SakTopBar(),
              const SizedBox(height: 16),
              ScreenTitle(
                'My evidence',
                subtitle: all.isEmpty
                    ? 'Sealed and encrypted the moment they stop'
                    : '${all.length} recording${all.length == 1 ? '' : 's'} · sealed and encrypted',
              ),
              const SizedBox(height: 16),
              if (all.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (f, label) in const [(_Filter.all, 'All'), (_Filter.ledger, 'On ledger'), (_Filter.pending, 'Pending')])
                      _Chip(label: label, selected: _filter == f, onTap: () => setState(() => _filter = f)),
                  ],
                ),
              const SizedBox(height: 16),
              Expanded(
                child: all.isEmpty
                    ? const Center(
                        child: SakEmptyState(
                          icon: Icons.video_library_outlined,
                          title: 'No evidence recorded yet',
                          message: 'Recordings appear here, sealed and encrypted, the moment they stop.',
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: shown.length + 1,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          if (i == shown.length) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 14, bottom: 12),
                              child: Text(
                                'Each recording is named by its SHA-256 fingerprint.\nAny change to the file would change it.',
                                textAlign: TextAlign.center,
                                style: context.type.labelSmall?.copyWith(color: Ember.ink3, height: 17 / 12),
                              ),
                            );
                          }
                          return Reveal(index: i, child: _EvidenceCard(entry: shown[i]));
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ));
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SakMotion.of(context, SakMotion.quick),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? Ember.ink : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? Ember.ink : const Color(0x24FFFFFF)),
          ),
          child: Text(
            label,
            style: TextStyle(fontFamily: SakFont.body, fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Ember.onPearl : const Color(0xCCF4ECEE)),
          ),
        ),
      ),
    );
  }
}

/// "Today, 15:52" for today, "21/10/2026, 22:14" otherwise.
String formatWhen(DateTime? when) {
  if (when == null) return 'Recording';
  final now = DateTime.now();
  final hm = '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
  if (when.year == now.year && when.month == now.month && when.day == now.day) return 'Today, $hm';
  return '${when.day.toString().padLeft(2, '0')}/${when.month.toString().padLeft(2, '0')}/${when.year}, $hm';
}

class _EvidenceCard extends StatelessWidget {
  const _EvidenceCard({required this.entry});
  final MapEntry<dynamic, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final data = Map<String, dynamic>.from(entry.value as Map);
    final hash = data['hash'] as String? ?? entry.key.toString();
    final cipherPath = data['path'] as String?;
    final wrappedKey = data['wrappedKey'] as String?;
    final status = data['status'] as String? ?? 'unknown';
    // Restored from the ledger after a recovery: no local file;
    // fetched from IPFS and opened with the recovery code's key.
    final restored = status == RecoveryService.restoredStatus;
    final canPlay = restored || (cipherPath != null && wrappedKey != null);

    final (color, label, thumb) = switch (status) {
      _ when restored => (Ember.rose, 'Restored from ledger', const [Color(0xFF5E6B8C), Color(0xFF1C2030)]),
      'anchored' => (Ember.sealed, 'Anchored on ledger', const [Color(0xFFE8899A), Color(0xFF5A1424)]),
      'uploaded_to_ipfs' => (Ember.sealed, 'Uploaded to IPFS', const [Color(0xFF8A5CC2), Color(0xFF2A1650)]),
      'locally_secured' => (Ember.attention, 'Upload pending', const [Color(0xFFF2B58C), Color(0xFF6A2A1F)]),
      _ => (Ember.attention, status, const [Color(0xFFF2B58C), Color(0xFF6A2A1F)]),
    };
    final whenText = formatWhen(DateTime.tryParse(data['timestamp'] as String? ?? '')?.toLocal());
    // Recordings shared with the simulated police: whether they hold their piece yet.
    final share = data['authorityShare'] as Map?;
    final police = data['authorityMsp'] == null || share?['skipped'] != null
        ? null
        : share == null
            ? const StatusPill(label: 'Police piece pending', color: Ember.attention, icon: Icons.local_police_outlined)
            : const StatusPill(label: 'Police hold 1 piece', color: Ember.rose, icon: Icons.local_police_outlined);

    return Semantics(
      button: canPlay,
      label: 'Recording $whenText, $label${police != null ? ', shared with the police' : ''}',
      child: Pressable(
        enabled: canPlay,
        child: GestureDetector(
          onTap: !canPlay
              ? null
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => EvidencePlayerScreen(
                        loadPlaintext: () => restored
                            ? RecoveryService.openRestoredClip(hash)
                            : EvidenceVaultService.openOwnClip(entry.key as String),
                        title: whenText,
                        label: hash.length > 12 ? hash.substring(0, 12) : hash,
                      ),
                    ),
                  ),
          child: Glass(
            radius: 24,
            padding: const EdgeInsets.all(12),
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: LinearGradient(begin: const Alignment(-0.4, -1), end: const Alignment(0.4, 1), colors: thumb, stops: const [0, 0.7]),
                    ),
                    child: Icon(restored ? Icons.restore_rounded : Icons.lock_outline_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(whenText, style: context.type.titleMedium?.copyWith(fontSize: 16)),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            StatusPill(label: label, color: color),
                            if (police != null) police,
                          ],
                        ),
                        const SizedBox(height: 5),
                        MonoText(hash.length > 8 ? hash.substring(0, 8) : hash, style: const TextStyle(fontSize: 12, color: Color(0x99F4ECEE))),
                      ],
                    ),
                  ),
                  if (canPlay) const Icon(Icons.chevron_right_rounded, color: Color(0x80F4ECEE)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
