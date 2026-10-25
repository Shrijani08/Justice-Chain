import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/authority_service.dart';
import '../core/evidence_encryptor.dart';
import '../logic/guardian_manager.dart';
import 'design/components.dart';
import 'design/tokens.dart';
import 'home_screen.dart';
import 'police_requests_screen.dart';

/// Paired guardians, with rename and remove on each one's sheet.
class GuardiansScreen extends StatelessWidget {
  const GuardiansScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return EmberScaffold(
      glows: const [
        Glow(color: Ember.wineGlow, width: 380, height: 300, opacity: 0.9, left: -120, top: -80),
        Glow(color: Ember.plumGlow, width: 260, height: 260, right: -110, bottom: 120),
      ],
      child: ValueListenableBuilder(
        valueListenable: Hive.box('vault_box').listenable(
          keys: ['trusted_guardians', GuardianManager.allowSingleGuardianKey, AuthorityService.optInKey],
        ),
        builder: (context, _, _) {
          final guardians = GuardianManager.getTrustedGuardians().entries
              .map((e) => _Guardian.from(e.key as String, e.value as Map))
              .toList()
            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          final withKeys = guardians.where((g) => g.canHoldKeys).length;
          const quorum = EvidenceEncryptor.guardianQuorum;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SakTopBar(
                trailing: CircleButton(icon: Icons.add_rounded, label: 'Add guardian', onTap: () => SafetyActions.addGuardian(context)),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 16, bottom: 16),
                  children: [
                    const ScreenTitle('Guardians'),
                    const SizedBox(height: 16),
                    Reveal(child: _QuorumCard(withKeys: withKeys, total: guardians.length, quorum: quorum)),
                    const SizedBox(height: 16),
                    if (guardians.isEmpty)
                      const SakEmptyState(
                        icon: Icons.group_add_outlined,
                        title: 'No guardians yet',
                        message: 'Add someone you trust. Scan the QR code on their phone.',
                      )
                    else
                      Reveal(
                        index: 1,
                        child: SakGroup(
                          children: [for (final g in guardians) _GuardianTile(guardian: g)],
                        ),
                      ),
                    const SizedBox(height: 16),
                    Reveal(index: 2, child: _SingleGuardianSwitch(enabled: GuardianManager.allowSingleGuardian)),
                    if (AuthorityService.demoBuild) ...[
                      const SizedBox(height: 16),
                      Reveal(index: 3, child: _PoliceGuardianCard(enabled: AuthorityService.sharesWithAuthority)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SakButton(label: 'Add guardian', icon: Icons.add_rounded, onPressed: () => SafetyActions.addGuardian(context)),
            ],
          );
        },
      ),
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

  String paired({bool year = false}) {
    final a = addedAt?.toLocal();
    if (a == null) return '';
    final d = '${a.day.toString().padLeft(2, '0')}/${a.month.toString().padLeft(2, '0')}';
    return ' · paired $d${year ? '/${a.year}' : ''}';
  }
}

class _QuorumCard extends StatelessWidget {
  const _QuorumCard({required this.withKeys, required this.total, required this.quorum});
  final int withKeys;
  final int total;
  final int quorum;

  @override
  Widget build(BuildContext context) {
    final ok = withKeys >= quorum;
    final tone = ok ? Ember.sealed : Ember.attention;
    final single = GuardianManager.allowSingleGuardian;
    final message = ok
        ? 'A recording opens only when $quorum guardians combine their pieces.'
        : single
            ? 'Single-guardian mode is on: any one guardian can open your new recordings.'
            : 'Add at least $quorum guardians. A recording opens only when $quorum of them combine their pieces.';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [tone.withValues(alpha: 0.16), tone.withValues(alpha: 0.04)]),
        border: Border.all(color: tone.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.key_rounded, size: 20, color: tone),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  total == 0 ? 'No key holders yet' : '$withKeys of $total can hold key pieces',
                  style: context.type.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < quorum; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: AnimatedContainer(
                    duration: SakMotion.of(context, SakMotion.standard),
                    height: 6,
                    decoration: BoxDecoration(
                      color: i < withKeys ? tone : const Color(0x1FFFFFFF),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(message, style: context.type.bodySmall?.copyWith(color: const Color(0xB3F4ECEE))),
        ],
      ),
    );
  }
}

/// Opt-in for victims with only one person they trust. Turning it on
/// explains the trade-off first; turning it off needs no confirmation.
class _SingleGuardianSwitch extends StatelessWidget {
  const _SingleGuardianSwitch({required this.enabled});
  final bool enabled;

  Future<void> _set(BuildContext context, bool value) async {
    if (value &&
        !await confirmSak(
          context,
          title: 'Let one guardian open recordings?',
          message: "Normally 2 guardians must combine their key pieces, so one person alone can't watch a recording.\n\n"
              'With this on, while you have fewer than 2 guardians, any one guardian can open your new recordings on their own. '
              'Recordings made this way stay that way, even after you add more guardians.\n\n'
              'Only turn this on if you fully trust your guardian.',
          confirmLabel: 'Turn on',
        )) {
      return;
    }
    await GuardianManager.setAllowSingleGuardian(value);
  }

  @override
  Widget build(BuildContext context) {
    return Glass(
      child: SakRow(
        title: 'Let one guardian open my recordings',
        subtitle: 'Only while you have fewer than ${EvidenceEncryptor.guardianQuorum} guardians',
        titleStyle: context.type.bodyMedium,
        chevron: false,
        trailing: SakSwitch(value: enabled, onChanged: (v) => _set(context, v)),
        onTap: () => _set(context, !enabled),
      ),
    );
  }
}

/// The simulated police as an extra key holder: one piece of each new
/// recording, never enough to open it alone. Turning it on explains that
/// first; turning it off needs no confirmation.
class _PoliceGuardianCard extends StatelessWidget {
  const _PoliceGuardianCard({required this.enabled});
  final bool enabled;

  Future<void> _set(BuildContext context, bool value) async {
    if (value &&
        !await confirmSak(
          context,
          title: 'Add the police as a guardian?',
          message: 'The Demo Police Authority gets one key piece of each new recording. '
              'One piece can never open a recording, so they must ask first, and only you or one of your guardians can say yes.\n\n'
              'Recordings made before you turn this on are not shared. Recordings that a single guardian can open are never shared.\n\n'
              'This is a SIMULATED police authority. No real police are contacted. In an emergency call 112.',
          confirmLabel: 'Add police',
        )) {
      return;
    }
    await AuthorityService.setShareWithAuthority(value);
  }

  @override
  Widget build(BuildContext context) {
    final available = AuthorityService.available;
    return SakGroup(
      header: 'Police guardian',
      footer: available
          ? 'No real police are contacted. In an emergency call 112.'
          : 'Needs the ledger connection (LEDGER=fabric in .env).',
      children: [
        SakRow(
          leading: const IconTile(icon: Icons.local_police_outlined, color: Ember.rose),
          title: 'Demo Police Authority',
          subtitle: enabled ? 'Holds 1 key piece of each new recording' : 'SIMULATED · not added',
          titleStyle: context.type.bodyMedium,
          chevron: false,
          enabled: available,
          trailing: SakSwitch(value: enabled, onChanged: available ? (v) => _set(context, v) : null),
          onTap: available ? () => _set(context, !enabled) : null,
        ),
        SakRow(
          icon: Icons.mark_email_unread_outlined,
          iconColor: Ember.attention,
          title: 'Police requests',
          subtitle: 'Approve or ignore requests to open a recording',
          titleStyle: context.type.bodyMedium,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PoliceRequestsScreen())),
        ),
      ],
    );
  }
}

class _GuardianTile extends StatelessWidget {
  const _GuardianTile({required this.guardian});
  final _Guardian guardian;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${guardian.name}. Options',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openSheet(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: ExcludeSemantics(
            child: Row(
              children: [
                Avatar(name: guardian.name, size: 42, muted: !guardian.canHoldKeys),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(guardian.name, style: context.type.titleMedium?.copyWith(fontSize: 16)),
                      const SizedBox(height: 2),
                      if (guardian.canHoldKeys)
                        MonoText('ID ${guardian.shortId}${guardian.paired()}', style: const TextStyle(fontSize: 12, color: Ember.ink2))
                      else
                        const Text("Can't hold key pieces. Pair again to fix.", style: TextStyle(fontFamily: SakFont.body, fontSize: 12, color: Ember.attention)),
                    ],
                  ),
                ),
                const SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(Icons.more_horiz_rounded, color: Color(0xB3F4ECEE)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final removed = await showSakSheet<bool>(context, (context) => _GuardianSheet(guardian: guardian));
    if (removed == true) messenger.showSnackBar(SnackBar(content: Text('${guardian.name} removed.')));
  }
}

/// Rename and remove for one guardian. Pops true once removed.
class _GuardianSheet extends StatefulWidget {
  const _GuardianSheet({required this.guardian});
  final _Guardian guardian;

  @override
  State<_GuardianSheet> createState() => _GuardianSheetState();
}

class _GuardianSheetState extends State<_GuardianSheet> {
  late final _name = TextEditingController(text: widget.guardian.name);
  bool _confirmRemove = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isNotEmpty && name != widget.guardian.name) {
      await GuardianManager.renameGuardian(widget.guardian.nodeId, name);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _remove() async {
    await GuardianManager.removeGuardian(widget.guardian.nodeId);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.guardian;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Avatar(name: g.name, size: 56),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.name, style: context.type.headlineSmall),
                  const SizedBox(height: 3),
                  MonoText('ID ${g.shortId}${g.paired(year: true)}', style: const TextStyle(fontSize: 12, color: Ember.ink2)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const FieldLabel('Name'),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          style: context.type.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
          decoration: sakField(),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 12),
        SakButton(label: 'Save name', style: SakButtonStyle.pearl, height: 54, fontSize: 16, onPressed: _save),
        const SizedBox(height: 18),
        const Divider(height: 1, color: Color(0x14FFFFFF)),
        const SizedBox(height: 18),
        Text('Remove ${g.name}?', style: context.type.titleSmall?.copyWith(color: Ember.alertText)),
        const SizedBox(height: 8),
        for (final line in const [
          'Stops receiving key pieces and clips from your new recordings.',
          "Key pieces already sent for earlier recordings can't be taken back.",
          'Scan their QR again to re-add them.',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(padding: EdgeInsets.only(top: 7, right: 8), child: CircleAvatar(radius: 2, backgroundColor: Color(0xB8F4ECEE))),
                Expanded(child: Text(line, style: context.type.bodySmall?.copyWith(height: 19 / 13, color: const Color(0xB8F4ECEE)))),
              ],
            ),
          ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: SakButton(
                label: 'Cancel',
                style: SakButtonStyle.glass,
                height: 54,
                fontSize: 16,
                onPressed: () => _confirmRemove ? setState(() => _confirmRemove = false) : Navigator.pop(context),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SakButton(
                label: _confirmRemove ? 'Yes, remove' : 'Remove',
                icon: Icons.delete_outline_rounded,
                style: SakButtonStyle.destructive,
                height: 54,
                fontSize: 16,
                // Two taps: a stray one never removes a guardian.
                onPressed: () => _confirmRemove ? _remove() : setState(() => _confirmRemove = true),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
