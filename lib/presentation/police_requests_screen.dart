import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/authority_service.dart';
import '../core/mesh_service.dart';
import '../logic/guardian_manager.dart';
import 'design/components.dart';
import 'pin_gate.dart';
import 'design/tokens.dart';
import 'evidence_viewer_screen.dart';

/// The simulated police's access requests: for the user's own recordings
/// (the user approves by issuing a new key piece) and for recordings of
/// people they protect (they release the piece they were given).
class PoliceRequestsScreen extends StatefulWidget {
  const PoliceRequestsScreen({super.key});

  @override
  State<PoliceRequestsScreen> createState() => _PoliceRequestsScreenState();
}

typedef _Requests = ({List<Map<String, dynamic>> mine, List<Map<String, dynamic>> guarded});

class _PoliceRequestsScreenState extends State<PoliceRequestsScreen> {
  late Future<_Requests> _requests = _load();

  static Future<_Requests> _load() async {
    final (mine, guarded) = await (
      AuthorityService.openRequestsForMyRecordings(),
      AuthorityService.openRequestsIGuard(),
    ).wait;
    return (mine: mine, guarded: guarded);
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _requests = next);
    await next.catchError((_) => (mine: <Map<String, dynamic>>[], guarded: <Map<String, dynamic>>[]));
  }

  @override
  Widget build(BuildContext context) {
    return PinGate(child: EmberScaffold(
      glows: const [
        Glow(color: Ember.wineGlow, width: 380, height: 300, opacity: 0.9, left: -120, top: -80),
        Glow(color: Ember.plumGlow, width: 260, height: 260, right: -110, bottom: 120),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SakTopBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 16, bottom: 16),
                children: [
                  const ScreenTitle(
                    'Police requests',
                    subtitle: 'The police must ask before they can open a recording. Nothing opens unless you or a guardian release a key piece.',
                  ),
                  const SizedBox(height: 16),
                  const SakNotice(
                    tone: NoticeTone.info,
                    icon: Icons.local_police_outlined,
                    title: 'Demo Police Authority (SIMULATED)',
                    message: 'A demo of how police access would work. No real police are contacted. In an emergency call 112.',
                  ),
                  const SizedBox(height: 16),
                  if (!AuthorityService.available)
                    const SakNotice(
                      title: 'Not connected to the ledger',
                      message: 'Police requests come from the Fabric ledger. This build has no ledger connection (LEDGER=fabric and GATEWAY_URL in .env).',
                    )
                  else
                    FutureBuilder<_Requests>(
                      future: _requests,
                      builder: (context, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const Padding(
                            padding: EdgeInsets.all(SakSpace.xxl),
                            child: Center(child: CircularProgressIndicator(strokeWidth: 2.6)),
                          );
                        }
                        if (snap.hasError) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SakNotice(
                                tone: NoticeTone.alarm,
                                title: "Couldn't reach the ledger",
                                message: 'Check the internet connection and try again.',
                              ),
                              const SizedBox(height: 12),
                              SakButton(label: 'Try again', style: SakButtonStyle.glass, height: 50, fontSize: 16, onPressed: _refresh),
                            ],
                          );
                        }
                        final r = snap.data!;
                        if (r.mine.isEmpty && r.guarded.isEmpty) {
                          return const SakEmptyState(
                            icon: Icons.verified_user_outlined,
                            title: 'No requests',
                            message: 'When the police ask to open a recording, it shows up here. Pull down to check again.',
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (r.mine.isNotEmpty) ...[
                              const GroupLabel('Your recordings'),
                              for (final (i, req) in r.mine.indexed)
                                Reveal(index: i, child: _RequestCard(request: req, own: true)),
                            ],
                            if (r.guarded.isNotEmpty) ...[
                              if (r.mine.isNotEmpty) const SizedBox(height: 10),
                              const GroupLabel('People you protect'),
                              for (final (i, req) in r.guarded.indexed)
                                Reveal(index: i, child: _RequestCard(request: req, own: false)),
                            ],
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ));
  }
}

/// Asks the user to confirm, then releases one key piece for [requestId].
/// [own] is true for the user's own recording; [owner] names whose
/// recording it is when they are its guardian. Returns whether they released.
Future<bool> confirmPoliceRelease(BuildContext context, {required String requestId, required bool own, String owner = ''}) async {
  final message = own
      ? 'This lets the Demo Police Authority open this one recording. They hold one key piece already; this makes the second.\n\n'
          'Your phone signs the release, the Auditor co-signs it, and it is recorded on the ledger. It can’t be taken back.'
      : 'This gives the Demo Police Authority your key piece for $owner’s recording. With the piece they already hold, they can open it.\n\n'
          'Your phone signs the release, the Auditor co-signs it, and it is recorded on the ledger. It can’t be taken back.';
  if (!await confirmSak(
    context,
    title: own ? 'Let the police open this recording?' : 'Release your key piece?',
    message: message,
    confirmLabel: 'Release',
  )) {
    return false;
  }
  await AuthorityService.approveRequest(requestId);
  return true;
}

class _RequestCard extends StatefulWidget {
  const _RequestCard({required this.request, required this.own});
  final Map<String, dynamic> request;

  /// True for the user's own recording, false for one they guard.
  final bool own;

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  String get _id => widget.request['requestId'] as String;
  String get _hash => widget.request['manifestHash'] as String;

  /// Whose recording this is, for a guardian: the name they paired under.
  String get _owner {
    final victim = widget.request['victimNodeId'] as String? ?? '';
    final name = (GuardianManager.getTrustedGuardians()[victim] as Map?)?['name'] as String?;
    if (name != null && name.trim().isNotEmpty) return name;
    return victim.length > 8 ? 'ID ${victim.substring(0, 4)}…${victim.substring(victim.length - 4)}' : 'someone you protect';
  }

  DateTime? get _recordedAt {
    if (widget.own) {
      final record = Hive.box('vault_box').get(_hash);
      return record is Map ? DateTime.tryParse(record['timestamp'] as String? ?? '')?.toLocal() : null;
    }
    for (final s in Hive.box(MeshService.receivedSharesBoxName).values.whereType<Map>()) {
      if (s['manifestHash'] == _hash) return DateTime.tryParse(s['capturedAt'] as String? ?? '')?.toLocal();
    }
    return null;
  }

  Future<void> _release() async {
    if (await confirmPoliceRelease(context, requestId: _id, own: widget.own, owner: _owner) && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final requestedAt = r['requestedAt'] is num
        ? DateTime.fromMillisecondsSinceEpoch((r['requestedAt'] as num).toInt() * 1000)
        : null;
    final recorded = _recordedAt;
    final started = AuthorityService.releaseStarted(_id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Glass(
        radius: 24,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const IconTile(icon: Icons.local_police_outlined, color: Ember.rose, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Demo Police Authority', style: context.type.titleMedium?.copyWith(fontSize: 16)),
                      const SizedBox(height: 2),
                      Text(
                        widget.own ? 'Asks to open your recording' : 'Asks to open $_owner’s recording',
                        style: context.type.labelSmall?.copyWith(color: Ember.ink2),
                      ),
                    ],
                  ),
                ),
                const StatusPill(label: 'SIMULATED', color: Ember.attention),
              ],
            ),
            const SizedBox(height: 14),
            _Line(label: 'Case', value: r['caseRef'] as String? ?? '—'),
            _Line(label: 'Reason', value: '“${r['reason'] ?? ''}”'),
            _Line(label: 'Recording', value: recorded != null ? formatWhen(recorded) : 'Clip ${_hash.substring(0, 8)}', mono: recorded == null),
            if (requestedAt != null) _Line(label: 'Asked', value: formatWhen(requestedAt.toLocal())),
            _Line(label: 'Asked by', value: r['requestedBy'] as String? ?? 'an officer'),
            const SizedBox(height: 12),
            if (started)
              const SakNotice(
                tone: NoticeTone.sealed,
                title: 'Release sent',
                message: 'Your phone is sending the key piece. It retries on its own if you are offline.',
              )
            else
              SakButton(
                label: widget.own ? 'Allow and release a piece' : 'Release my key piece',
                icon: Icons.key_rounded,
                style: SakButtonStyle.pearl,
                height: 52,
                fontSize: 16,
                onPressed: _release,
              ),
            if (!started) ...[
              const SizedBox(height: 8),
              Text(
                'If you do nothing, the police can’t open it.',
                textAlign: TextAlign.center,
                style: context.type.labelSmall?.copyWith(color: Ember.ink3),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, this.mono = false});
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 84, child: Text(label, style: context.type.bodySmall?.copyWith(color: Ember.ink2))),
          Expanded(
            child: mono
                ? MonoText(value, style: const TextStyle(fontSize: 13))
                : Text(value, style: context.type.bodySmall?.copyWith(color: Ember.ink)),
          ),
        ],
      ),
    );
  }
}
