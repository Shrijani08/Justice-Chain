import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/disguise_service.dart';
import '../core/identity_service.dart';
import '../core/protection_service.dart';
import '../logic/guardian_manager.dart';
import 'design/components.dart';
import 'design/tokens.dart';
import 'guardians_screen.dart';
import 'recovery_code_screen.dart';
import 'setup_screens.dart';

/// One line of the "Keep it running" check.
class HealthItem {
  const HealthItem({required this.title, required this.ok, required this.detail, required this.icon, this.fix});
  final String title;
  final bool ok;
  final String detail;
  final IconData icon;

  /// The screen that fixes it, when it isn't ok.
  final Widget Function()? fix;
}

/// Reads this phone's state for background protection.
abstract final class BackgroundHealth {
  static Future<List<HealthItem>> check() async {
    final camera = await Permission.camera.isGranted;
    final mic = await Permission.microphone.isGranted;
    final running = await ProtectionService.isRunning();
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    final disguised = DisguiseService.enabled.value;
    final nameShows = disguised && await ProtectionService.disguisedNotificationVisible();
    return [
      HealthItem(
        title: 'Camera and microphone',
        ok: camera && mic,
        detail: camera && mic ? 'While using the app' : 'Not allowed yet',
        icon: Icons.mic_none_rounded,
        fix: () => const PermissionsScreen(fromGuide: true),
      ),
      HealthItem(
        title: 'Protection running',
        ok: running || !ProtectionService.enabled.value,
        detail: !ProtectionService.enabled.value
            ? 'Turned off in Profile'
            : running
                ? 'Background notification is up'
                : 'Open Sakshya once to start it',
        icon: Icons.notifications_none_rounded,
        fix: () => const BackgroundNoticeScreen(fromGuide: true),
      ),
      HealthItem(
        title: 'Battery',
        ok: battery,
        detail: battery ? 'Allowed to run in background' : 'The battery saver may close it',
        icon: Icons.battery_5_bar_rounded,
        fix: () => const BatteryScreen(fromGuide: true),
      ),
      HealthItem(
        title: 'Hidden name',
        ok: !nameShows,
        detail: !disguised
            ? 'Only needed with the disguise'
            : nameShows
                ? 'Disguise on, “Sakshya” still shows'
                : 'The notification is hidden',
        icon: Icons.visibility_off_outlined,
        fix: () => const HideNotificationScreen(fromGuide: true),
      ),
    ];
  }

  static Future<int> problems() async => (await check()).where((i) => !i.ok).length;
}

/// Everything a new user should finish, in one list: her guardians and her
/// recovery code, then the background checks. Home shows how far she is
/// until it is all done.
abstract final class SafetySetup {
  static const minGuardians = 2;

  static Future<List<HealthItem>> check() async => [
        guardiansItem(GuardianManager.getTrustedGuardians().length),
        recoveryCodeItem(saved: await IdentityService.pendingRecoveryCode() == null),
        ...await BackgroundHealth.check(),
      ];

  static ({int done, int total}) progress(List<HealthItem> items) =>
      (done: items.where((i) => i.ok).length, total: items.length);

  @visibleForTesting
  static HealthItem guardiansItem(int paired) => HealthItem(
        title: 'Guardians',
        ok: paired >= minGuardians,
        detail: switch (paired) {
          0 => 'Add $minGuardians people you trust',
          1 => '1 paired; add 1 more so a clip can be opened',
          _ => '$paired paired',
        },
        icon: Icons.group_outlined,
        fix: () => const GuardiansScreen(),
      );

  @visibleForTesting
  static HealthItem recoveryCodeItem({required bool saved}) => HealthItem(
        title: 'Recovery code',
        ok: saved,
        detail: saved ? 'Written down' : 'Write it down, or a lost phone loses your clips',
        icon: Icons.key_rounded,
        fix: () => Builder(builder: (context) => RecoveryCodeScreen(onDone: () => Navigator.pop(context))),
      );
}

/// The user guide, from Home's ? and Profile.
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key});

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  late Future<int> _problems = BackgroundHealth.problems();

  void _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() => _problems = BackgroundHealth.problems());
  }

  Widget _topic(GuideTopic t) => SakRow(
        icon: t.icon,
        iconColor: t.color,
        title: t.title,
        onTap: () => _open(GuideTopicScreen(topic: t)),
      );

  @override
  Widget build(BuildContext context) {
    return EmberScaffold(
      glows: const [
        Glow(color: Color(0xFF6A1A2E), width: 420, height: 340, opacity: 0.75, left: -15, top: -140),
        Glow(color: Ember.nightPlum, width: 320, height: 300, opacity: 0.85, left: -140, bottom: 40),
      ],
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        children: [
          const SakTopBar(title: 'User guide'),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                Reveal(
                  child: Semantics(
                    button: true,
                    child: Pressable(
                      child: GestureDetector(
                        onTap: () => _open(const GuideTopicScreen(topic: GuideTopic.danger)),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [Ember.emberStart, Ember.emberEnd], stops: [0, 0.75]),
                            borderRadius: BorderRadius.circular(SakRadius.card),
                            border: Border.all(color: Ember.emberEdge),
                            boxShadow: const [BoxShadow(color: Color(0x8C5A0F22), blurRadius: 36, offset: Offset(0, 16))],
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x2EFFFFFF)),
                                child: const Icon(Icons.shield_outlined, color: Colors.white, size: 22),
                              ),
                              const SizedBox(width: 14),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('In danger right now?', style: TextStyle(fontFamily: SakFont.body, fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                                    SizedBox(height: 2),
                                    Text('What to do, step by step', style: TextStyle(fontFamily: SakFont.body, fontSize: 13, color: Color(0xE0FFFFFF))),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded, color: Colors.white),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Reveal(
                  index: 1,
                  child: SakGroup(header: 'Recording', children: [
                    _topic(GuideTopic.sos),
                    _topic(GuideTopic.listening),
                    _topic(GuideTopic.disguise),
                  ]),
                ),
                const SizedBox(height: 16),
                Reveal(
                  index: 2,
                  child: SakGroup(header: 'After a recording', children: [
                    _topic(GuideTopic.sealed),
                    _topic(GuideTopic.opening),
                  ]),
                ),
                const SizedBox(height: 16),
                Reveal(
                  index: 3,
                  child: FutureBuilder<int>(
                    future: _problems,
                    builder: (context, snap) {
                      final n = snap.data ?? 0;
                      return SakGroup(header: 'Your setup', children: [
                        SakRow(
                          icon: Icons.battery_5_bar_rounded,
                          iconColor: n > 0 ? Ember.attention : Ember.sealed,
                          title: 'Keep it running',
                          trailing: n > 0 ? StatusPill(label: '$n to fix', color: Ember.attention) : null,
                          onTap: () => _open(const GuideBackgroundScreen()),
                        ),
                        _topic(GuideTopic.guardians),
                        _topic(GuideTopic.lostPhone),
                      ]);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A guide page: numbered steps on a rail, an optional closing note.
class GuideTopic {
  const GuideTopic({
    required this.title,
    required this.lead,
    required this.icon,
    required this.color,
    required this.steps,
    this.note,
    this.noteIcon = Icons.info_outline_rounded,
  });

  final String title;
  final String lead;
  final IconData icon;
  final Color color;
  final List<(String, String)> steps;
  final String? note;
  final IconData noteIcon;

  static const danger = GuideTopic(
    title: "If you're in danger",
    lead: 'Do whichever you can. Each one starts a sealed recording.',
    icon: Icons.shield_outlined,
    color: Color(0xFFFF8FA3),
    steps: [
      ('Tap SOS', 'On the home screen. Recording starts at once.'),
      ('Disguised? Type 112 =', 'The calculator starts recording with nothing on screen.'),
      ("Can't reach your phone?", 'While listening is on, a scream starts recording by itself.'),
      ('Keep it recording', 'You can lock the screen or put the phone away. It keeps going.'),
      ("When you're safe, stop", 'The clip is sealed so nobody can change it. Only your guardians, together, can open it.'),
    ],
    note: 'Sakshya saves proof. If you can, also call 112.',
    noteIcon: Icons.call_outlined,
  );

  static const sos = GuideTopic(
    title: 'Record with SOS',
    lead: 'The fastest way to record. It never waits for the AI.',
    icon: Icons.videocam_outlined,
    color: Color(0xFFFF8FA3),
    steps: [
      ('Tap the red SOS bar', 'It is on the home screen, under the orb.'),
      ('Recording starts at once', 'Camera and microphone record together.'),
      ('Stop & seal when safe', 'Or let it stop on its own after 45 seconds.'),
      ('Check it was sealed', 'The Sealed screen shows each step as it finishes.'),
    ],
  );

  static const listening = GuideTopic(
    title: 'How listening works',
    lead: 'An AI on this phone listens for screams and distress. Nothing is sent anywhere while it listens.',
    icon: Icons.graphic_eq_rounded,
    color: Color(0xFFFFB08F),
    steps: [
      ('It scores every second', 'Tap the orb on the home screen to see what it hears.'),
      ('It waits to be sure', 'Recording starts when the score stays above the line for 2 of 3 seconds.'),
      ('It keeps going in background', 'With the screen locked or the app closed, the background notification keeps it alive.'),
      ('A phone call pauses nothing', 'Listening carries on after you hang up.'),
    ],
  );

  static const disguise = GuideTopic(
    title: 'The calculator disguise',
    lead: 'Sakshya can open as a working calculator, so nobody sees what it is.',
    icon: Icons.calculate_outlined,
    color: Ember.ink,
    steps: [
      ('Turn it on in Profile', 'Profile › Calculator disguise. The app icon changes too.'),
      ('Type your PIN, then =', 'That opens the real app.'),
      ('Type 112 = to record', 'Recording starts behind the calculator.'),
      ('Hide the notification', 'Do it once, so the real name never shows.'),
    ],
  );

  static const sealed = GuideTopic(
    title: 'Sealed clips and where they go',
    lead: 'Every clip is locked the moment it stops.',
    icon: Icons.lock_outline_rounded,
    color: Color(0xFFC9A2F2),
    steps: [
      ('Encrypted on this phone', 'Only the encrypted copy is kept.'),
      ('Fingerprinted', 'Its SHA-256 fingerprint changes if anyone edits the file.'),
      ('Uploaded to IPFS', 'A copy leaves the phone as soon as there is internet.'),
      ('Anchored on the ledger', 'The fingerprint and time are written where nobody can change them.'),
    ],
    note: 'Find every clip under My evidence.',
  );

  static const opening = GuideTopic(
    title: 'Opening a clip with guardians',
    lead: 'No single person can open your clips. Two guardians must agree.',
    icon: Icons.key_rounded,
    color: Color(0xFFFF8FA3),
    steps: [
      ('Each guardian holds a key piece', 'Pieces are sent when your phones are near each other or online.'),
      ('Two pieces open a clip', 'One guardian sends their piece to another with Send my piece.'),
      ('Open & verify', 'The clip opens with its fingerprint, signature and ledger checked.'),
    ],
  );

  static const guardians = GuideTopic(
    title: 'Add, rename or remove guardians',
    lead: 'Guardians are people you trust. Add at least two.',
    icon: Icons.group_outlined,
    color: Color(0xFFFF8FA3),
    steps: [
      ('Add', 'Home › Add guardian, then scan the QR on their phone.'),
      ('They add you back', 'They open Add guardian › Scan their QR and scan yours.'),
      ('Rename or remove', 'Guardians › tap ••• next to a name.'),
    ],
  );

  static const lostPhone = GuideTopic(
    title: 'Lost or new phone',
    lead: 'Your recovery code brings back your identity and recordings.',
    icon: Icons.smartphone_rounded,
    color: Ember.ink,
    steps: [
      ('Install Sakshya', 'Open it and go through the welcome pages.'),
      ('Choose Restore', 'On Create your identity, tap “Lost your phone? Restore with recovery code”.'),
      ('Type your code', 'The six groups you wrote on paper.'),
      ('Pair your guardians again', 'Scan their QR codes once more.'),
    ],
  );
}

class GuideTopicScreen extends StatelessWidget {
  const GuideTopicScreen({super.key, required this.topic});
  final GuideTopic topic;

  @override
  Widget build(BuildContext context) {
    return EmberScaffold(
      background: Ember.home,
      glows: const [
        Glow(color: Ember.emberEnd, width: 420, height: 360, opacity: 0.7, left: -120, top: -140),
        Glow(color: Ember.nightPlum, width: 300, height: 280, opacity: 0.85, right: -140, bottom: 60),
      ],
      child: FillScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SakTopBar(title: 'Guide'),
            const SizedBox(height: 16),
            ScreenTitle(topic.title, subtitle: topic.lead, size: 32),
            const SizedBox(height: 20),
            for (var i = 0; i < topic.steps.length; i++)
              Reveal(
                index: i,
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Column(
                        children: [
                          _RailNumber(i + 1),
                          if (i < topic.steps.length - 1)
                            Expanded(
                              child: Container(
                                width: 2,
                                margin: const EdgeInsets.symmetric(vertical: 2),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Color(0x59D99AAB), Color(0x14D99AAB)],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: i < topic.steps.length - 1 ? 16 : 0, top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(topic.steps[i].$1, style: context.type.titleMedium),
                              const SizedBox(height: 3),
                              Text(topic.steps[i].$2, style: context.type.bodyMedium?.copyWith(fontSize: 14, height: 20 / 14, color: const Color(0xBDF4ECEE))),
                              if (topic == GuideTopic.danger && i == 0) ...[const SizedBox(height: 8), const _MiniSos()],
                              if (topic == GuideTopic.danger && i == 1) ...[const SizedBox(height: 8), const _MiniKeys()],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const Spacer(),
            if (topic.note != null) ...[
              const SizedBox(height: 24),
              Glass(
                radius: 20,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Icon(topic.noteIcon, size: 20, color: const Color(0xFFFF8FA3)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(topic.note!, style: context.type.bodyMedium?.copyWith(fontSize: 14))),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RailNumber extends StatelessWidget {
  const _RailNumber(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0x808E1B32),
        border: Border.all(color: const Color(0x59D99AAB)),
      ),
      child: Text('$n', style: const TextStyle(fontFamily: SakFont.display, fontSize: 15, fontWeight: FontWeight.w700, color: Ember.ink)),
    );
  }
}

class _MiniSos extends StatelessWidget {
  const _MiniSos();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        height: 32,
        padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
        decoration: BoxDecoration(gradient: Ember.emberGradient, borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x2EFFFFFF)),
              child: const Icon(Icons.videocam_outlined, size: 13, color: Colors.white),
            ),
            const SizedBox(width: 8),
            const Text('SOS · Start recording', style: TextStyle(fontFamily: SakFont.body, fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class _MiniKeys extends StatelessWidget {
  const _MiniKeys();

  @override
  Widget build(BuildContext context) {
    Widget k(String s, {bool op = false}) => Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          margin: const EdgeInsets.only(right: 5),
          decoration: BoxDecoration(color: op ? const Color(0xFF5F7A8A) : const Color(0xFF26292C), borderRadius: BorderRadius.circular(9)),
          child: Text(s, style: const TextStyle(fontFamily: SakFont.body, fontSize: 14, color: Colors.white)),
        );
    return ExcludeSemantics(child: Row(mainAxisSize: MainAxisSize.min, children: [k('1'), k('1'), k('2'), k('=', op: true)]));
  }
}

/// "Keep it running": this phone's background protection, checked live,
/// with a Fix for anything that isn't right. With [SafetySetup.check] it is
/// the "Finish setup" list instead.
class GuideBackgroundScreen extends StatefulWidget {
  const GuideBackgroundScreen({
    super.key,
    this.check = BackgroundHealth.check,
    this.title = 'Keep it running',
    this.subtitle = "Check this after a phone update, or if a recording didn't start.",
    this.showTips = true,
  });

  /// The setup checklist from Home.
  const GuideBackgroundScreen.setup({super.key})
      : check = SafetySetup.check,
        title = 'Finish setup',
        subtitle = 'Each item keeps your recordings safe. Tap Fix to do it now.',
        showTips = false;

  final Future<List<HealthItem>> Function() check;
  final String title;
  final String subtitle;
  final bool showTips;

  @override
  State<GuideBackgroundScreen> createState() => _GuideBackgroundScreenState();
}

class _GuideBackgroundScreenState extends State<GuideBackgroundScreen> with WidgetsBindingObserver {
  List<HealthItem>? _items;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final items = await widget.check();
    if (mounted) setState(() => _items = items);
  }

  Future<void> _fix(HealthItem item) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => item.fix!()));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final ready = items?.where((i) => i.ok).length ?? 0;
    final total = items?.length ?? 4;
    return EmberScaffold(
      glows: const [
        Glow(color: Ember.deepWine, width: 400, height: 320, opacity: 0.85, right: -140, top: -100),
        Glow(color: Ember.nightPlum, width: 300, height: 280, opacity: 0.85, left: -140, bottom: 80),
      ],
      child: FillScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SakTopBar(title: widget.showTips ? 'Guide' : 'Setup'),
            const SizedBox(height: 16),
            ScreenTitle(widget.title, subtitle: widget.subtitle, size: 32),
            const SizedBox(height: 16),
            Glass(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text('This phone', style: context.type.titleSmall),
                      const Spacer(),
                      MonoText(items == null ? 'checking…' : '$ready of $total ready', style: const TextStyle(color: Color(0xBFF4ECEE))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 6,
                      child: Stack(
                        children: [
                          const ColoredBox(color: Color(0x1AFFFFFF), child: SizedBox.expand()),
                          TweenAnimationBuilder<double>(
                            tween: Tween(end: items == null ? 0 : ready / total),
                            duration: SakMotion.of(context, const Duration(milliseconds: 900)),
                            curve: SakMotion.enter,
                            builder: (context, f, _) => FractionallySizedBox(
                              widthFactor: f,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(gradient: LinearGradient(colors: [Ember.emberStart, Ember.blush])),
                                child: SizedBox.expand(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (items == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else
              SakGroup(
                children: [
                  for (final item in items)
                    SakRow(
                      icon: item.icon,
                      iconColor: item.ok ? const Color(0xFFFF8FA3) : Ember.attention,
                      title: item.title,
                      subtitle: item.detail,
                      subtitleColor: item.ok ? null : Ember.attention,
                      chevron: false,
                      trailing: item.ok
                          ? const Text('Ready', style: TextStyle(fontFamily: SakFont.body, fontSize: 13, fontWeight: FontWeight.w600, color: Ember.sealed))
                          : _FixButton(onTap: () => _fix(item)),
                    ),
                ],
              ),
            if (widget.showTips) ...[
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Good to know', style: context.type.labelMedium),
                    const SizedBox(height: 10),
                    const _GoodToKnow(Icons.restart_alt_rounded, 'After the phone restarts, open Sakshya once to turn protection back on.'),
                    const SizedBox(height: 10),
                    const _GoodToKnow(Icons.call_outlined, 'A phone call pauses nothing. Listening carries on after you hang up.'),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FixButton extends StatelessWidget {
  const _FixButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Fix',
      child: Pressable(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Ember.attention, borderRadius: BorderRadius.circular(999)),
            child: const Text('Fix', style: TextStyle(fontFamily: SakFont.body, fontSize: 14, fontWeight: FontWeight.w700, color: Ember.onPearl)),
          ),
        ),
      ),
    );
  }
}

class _GoodToKnow extends StatelessWidget {
  const _GoodToKnow(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Ember.blush),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: context.type.bodyMedium?.copyWith(fontSize: 14, height: 20 / 14, color: const Color(0xCCF4ECEE)))),
      ],
    );
  }
}
