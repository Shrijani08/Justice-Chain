import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/evidence_encryptor.dart';
import '../logic/guardian_manager.dart';
import 'design/components.dart';
import 'design/tokens.dart';

/// Lists paired guardians with rename and remove. Adding still happens via
/// Scan QR on the home screen, which hands the camera over safely.
class GuardiansScreen extends StatelessWidget {
  const GuardiansScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Hive.box('vault_box').listenable(
        keys: ['trusted_guardians', GuardianManager.allowSingleGuardianKey],
      ),
      builder: (context, _, _) {
        final guardians = GuardianManager.getTrustedGuardians().entries
            .map((e) => _Guardian.from(e.key as String, e.value as Map))
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final withKeys = guardians.where((g) => g.canHoldKeys).length;
        final singleMode = GuardianManager.allowSingleGuardian;
        final belowQuorum = withKeys < EvidenceEncryptor.guardianQuorum;

        return SakPage(
          title: 'My Guardians',
          slivers: [
            SliverList.list(
              children: [
                AnimatedSize(
                  duration: SakMotion.of(context, SakMotion.standard),
                  curve: SakMotion.spring,
                  alignment: Alignment.topCenter,
                  child: belowQuorum
                      ? _QuorumWarning(withKeys: withKeys, singleMode: singleMode)
                      : const SizedBox(width: double.infinity),
                ),
                SakGroup(
                  footer: 'Only applies while you have fewer than '
                      '${EvidenceEncryptor.guardianQuorum} guardians.',
                  children: [_SingleGuardianSwitch(enabled: singleMode)],
                ),
                if (guardians.isEmpty)
                  const SakEmptyState(
                    icon: Icons.group_add_rounded,
                    title: 'No guardians yet',
                    message: 'Use Scan QR on the home screen to add someone you trust.',
                  )
                else
                  SakGroup(
                    header: guardians.length == 1 ? '1 guardian' : '${guardians.length} guardians',
                    children: [for (final g in guardians) _GuardianTile(guardian: g)],
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Guardian {
  const _Guardian({
    required this.nodeId,
    required this.name,
    required this.addedAt,
    required this.canHoldKeys,
  });

  factory _Guardian.from(String nodeId, Map data) => _Guardian(
        nodeId: nodeId,
        name: (data['name'] as String?)?.trim().isNotEmpty == true
            ? data['name'] as String
            : 'Unnamed guardian',
        addedAt: DateTime.tryParse(data['added_at'] as String? ?? ''),
        canHoldKeys: data['x25519_public_key'] != null,
      );

  final String nodeId;
  final String name;
  final DateTime? addedAt;
  final bool canHoldKeys;

  String get shortId => nodeId.length > 8
      ? '${nodeId.substring(0, 4)}…${nodeId.substring(nodeId.length - 4)}'
      : nodeId;
}

class _QuorumWarning extends StatelessWidget {
  const _QuorumWarning({required this.withKeys, required this.singleMode});
  final int withKeys;
  final bool singleMode;

  @override
  Widget build(BuildContext context) {
    final quorum = EvidenceEncryptor.guardianQuorum;
    final message = singleMode
        ? 'Single-guardian mode is on. While you have fewer than $quorum guardians, '
            'any one guardian can open your new recordings. You have $withKeys '
            'that can hold a key piece.'
        : 'Add at least $quorum guardians. A recording can only be opened '
            'when $quorum of them combine their key pieces. You have '
            '$withKeys that can hold one.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(SakSpace.lg, SakSpace.sm, SakSpace.lg, SakSpace.sm),
      child: SakNotice(
        tone: singleMode ? NoticeTone.info : NoticeTone.warning,
        message: message,
      ),
    );
  }
}

/// Opt-in for victims with only one person they trust. Turning it on
/// explains the trade-off first; turning it off needs no confirmation.
class _SingleGuardianSwitch extends StatelessWidget {
  const _SingleGuardianSwitch({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('Let one guardian open my recordings'),
      secondary: SakIconTile(icon: Icons.person_rounded, color: context.sak.warning),
      contentPadding: const EdgeInsets.symmetric(horizontal: SakSpace.lg, vertical: SakSpace.xs),
      value: enabled,
      onChanged: (value) async {
        if (value && !await _confirmEnable(context)) return;
        await GuardianManager.setAllowSingleGuardian(value);
      },
    );
  }

  Future<bool> _confirmEnable(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Let one guardian open recordings?'),
        content: const Text(
          "Normally 2 guardians must combine their key pieces to open a recording, "
          "so one person alone can't watch it.\n\n"
          'With this on, while you have fewer than 2 guardians:\n'
          '• Any one guardian can open your new recordings on their own.\n'
          '• Recordings made in this mode stay that way, even after you add more '
          'guardians or turn this off. A guardian added later can also open them alone.\n\n'
          'Only turn this on if you fully trust your guardian.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }
}

class _GuardianTile extends StatelessWidget {
  const _GuardianTile({required this.guardian});
  final _Guardian guardian;

  @override
  Widget build(BuildContext context) {
    final added = guardian.addedAt?.toLocal();
    final addedText = added == null
        ? ''
        : ' · paired ${added.day.toString().padLeft(2, '0')}/'
            '${added.month.toString().padLeft(2, '0')}/${added.year}';

    final c = context.sak;
    return SakRow(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: c.accentSoft,
        foregroundColor: c.accent,
        child: Text(
          guardian.name.characters.first.toUpperCase(),
          style: context.type.titleSmall?.copyWith(color: c.accent),
        ),
      ),
      title: guardian.name,
      subtitle: 'ID ${guardian.shortId}$addedText'
          '${guardian.canHoldKeys ? '' : '\nCan\'t hold key pieces. Pair again to fix.'}',
      chevron: false,
      trailing: PopupMenuButton<String>(
        tooltip: 'Options for ${guardian.name}',
        icon: Icon(Icons.more_horiz_rounded, color: c.inkSecondary),
        onSelected: (action) {
          if (action == 'rename') _rename(context);
          if (action == 'remove') _remove(context);
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'rename',
            child: ListTile(leading: Icon(Icons.edit_rounded), title: Text('Rename')),
          ),
          PopupMenuItem(
            value: 'remove',
            child: ListTile(
              leading: Icon(Icons.person_remove_rounded, color: c.danger),
              title: Text('Remove', style: TextStyle(color: c.danger)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: guardian.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename guardian'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || name.trim() == guardian.name) return;
    await GuardianManager.renameGuardian(guardian.nodeId, name);
  }

  Future<void> _remove(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${guardian.name}?'),
        content: const Text(
          '• They will stop receiving key pieces and clips from your new recordings.\n'
          '• Your phone will stop accepting clips they relay to you.\n'
          '• Key pieces they already received for earlier recordings can\'t be '
          'taken back.\n\n'
          'To add them again later, scan their QR code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await GuardianManager.removeGuardian(guardian.nodeId);
    messenger.showSnackBar(SnackBar(content: Text('${guardian.name} removed.')));
  }
}
