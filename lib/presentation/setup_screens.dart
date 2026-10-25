import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/protection_service.dart';
import 'design/components.dart';
import 'design/tokens.dart';
import 'home_screen.dart';

/// Background setup after the recovery code: permissions, the background
/// notification, hiding its name, and the battery saver. The guide opens
/// the same screens later with [fromGuide], where they end with Done.
abstract final class SetupFlow {
  static const batteryAskedKey = 'battery_exemption_asked';

  /// Leaves setup for the home screen, with nothing to go back to.
  static void finish(BuildContext context) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MainSafetyScreen()),
      (_) => false,
    );
  }

  static void next(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }
}

/// Re-reads phone state whenever the user comes back from Settings.
mixin _RefreshOnResume<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
  Future<void> refresh();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }
}

class _Perm {
  const _Perm(this.title, this.why, this.tap, this.icon, this.permissions);
  final String title;
  final String why;
  final String tap;
  final IconData icon;
  final List<Permission> permissions;
}

/// Setup 3: each permission, why it is needed, and what to tap.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key, this.fromGuide = false});
  final bool fromGuide;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver, _RefreshOnResume {
  static const _perms = [
    _Perm('Camera', 'Films what happens.', 'Tap “While using the app”', Icons.videocam_outlined, [Permission.camera]),
    _Perm('Microphone', 'Hears distress, records sound.', 'Tap “While using the app”', Icons.mic_none_rounded, [Permission.microphone]),
    _Perm('Notifications', 'Shows you when protection is on.', 'Tap “Allow”', Icons.notifications_none_rounded, [Permission.notification]),
    _Perm('Nearby devices', 'Reaches guardians with no internet.', 'Tap “Allow”', Icons.settings_input_antenna_rounded, [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ]),
    _Perm('Location', 'Android needs it to find nearby phones.', 'Tap “While using the app”', Icons.location_on_outlined, [Permission.location]),
  ];

  final _granted = List<bool>.filled(_perms.length, false);
  bool _asked = false;
  bool _busy = false;

  @override
  Future<void> refresh() async {
    for (var i = 0; i < _perms.length; i++) {
      _granted[i] = await _isGranted(_perms[i]);
    }
    if (mounted) setState(() {});
  }

  // permission_handler reports a permission this Android version doesn't
  // have (nearby Wi-Fi before 13, say) as granted.
  static Future<bool> _isGranted(_Perm p) async {
    for (final perm in p.permissions) {
      final s = await perm.status;
      if (!(s.isGranted || s.isLimited)) return false;
    }
    return true;
  }

  Future<void> _ask(int i) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final statuses = await _perms[i].permissions.request();
      if (statuses.values.any((s) => s.isPermanentlyDenied) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${_perms[i].title} is blocked. Allow it in Settings › Permissions.'),
          action: SnackBarAction(label: 'Open', onPressed: openAppSettings),
        ));
      }
    } finally {
      _asked = true;
      await refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _askAll() async {
    for (var i = 0; i < _perms.length; i++) {
      if (!_granted[i]) await _ask(i);
    }
  }

  void _continue() {
    if (widget.fromGuide) {
      Navigator.pop(context);
    } else {
      SetupFlow.next(context, const BackgroundNoticeScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = _granted.where((g) => !g).length;
    return PopScope(
      canPop: widget.fromGuide,
      child: EmberScaffold(
        glows: const [
          Glow(color: Ember.deepWine, width: 360, height: 300, right: -140, top: -80),
          Glow(color: Ember.nightPlum, width: 360, height: 320, opacity: 0.85, left: -160, top: 420),
        ],
        child: FillScroll(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.fromGuide) ...[const SakTopBar(), const SizedBox(height: 16)],
              const Reveal(
                child: ScreenTitle('Allow what it needs', subtitle: 'Android asks one at a time. Here is what to tap on each question.'),
              ),
              const SizedBox(height: 16),
              Reveal(
                index: 1,
                child: SakGroup(
                  children: [
                    for (var i = 0; i < _perms.length; i++) _PermRow(perm: _perms[i], granted: _granted[i], onTap: _granted[i] ? null : () => _ask(i)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Reveal(
                index: 2,
                child: SakNotice(
                  tone: NoticeTone.attention,
                  message: 'Never pick “Only this time”. Protection would stop as soon as the app closes.',
                ),
              ),
              const Spacer(),
              const SizedBox(height: 24),
              AnimatedSwitcher(
                duration: SakMotion.of(context, SakMotion.standard),
                child: left == 0
                    ? SakButton(
                        key: const ValueKey('continue'),
                        label: widget.fromGuide ? 'Done' : 'Continue',
                        style: SakButtonStyle.pearl,
                        onPressed: _continue,
                      )
                    : SakButton(
                        key: const ValueKey('allow'),
                        label: left == _perms.length ? 'Allow all' : 'Allow the rest ($left)',
                        loading: _busy,
                        onPressed: _askAll,
                      ),
              ),
              if (left > 0 && _asked)
                TextButton(onPressed: _continue, child: Text(widget.fromGuide ? 'Close' : 'Continue without them')),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermRow extends StatelessWidget {
  const _PermRow({required this.perm, required this.granted, required this.onTap});
  final _Perm perm;
  final bool granted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: '${perm.title}, ${granted ? 'allowed' : 'not allowed yet'}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0x598E1B32),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x4DC98597)),
                ),
                child: Icon(perm.icon, size: 18, color: Ember.blush),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(perm.title, style: context.type.titleMedium?.copyWith(fontSize: 16)),
                      Text(perm.why, style: context.type.bodySmall?.copyWith(color: const Color(0xB3F4ECEE))),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(8)),
                        child: Text(perm.tap, style: const TextStyle(fontFamily: SakFont.mono, fontSize: 11, color: Color(0xE0F4ECEE))),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _CheckRing(on: granted),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckRing extends StatelessWidget {
  const _CheckRing({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: SakMotion.of(context, const Duration(milliseconds: 220)),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? Ember.sealed : Colors.transparent,
        border: on ? null : Border.all(color: const Color(0x4DF4ECEE), width: 2),
      ),
      child: AnimatedScale(
        scale: on ? 1 : 0.5,
        duration: SakMotion.of(context, const Duration(milliseconds: 260)),
        curve: SakMotion.enter,
        child: AnimatedOpacity(
          opacity: on ? 1 : 0,
          duration: SakMotion.of(context, const Duration(milliseconds: 200)),
          child: const Icon(Icons.check_rounded, size: 17, color: Ember.ground),
        ),
      ),
    );
  }
}

/// Setup 4: why one notification stays on, normal and disguised.
class BackgroundNoticeScreen extends StatefulWidget {
  const BackgroundNoticeScreen({super.key, this.fromGuide = false});
  final bool fromGuide;

  @override
  State<BackgroundNoticeScreen> createState() => _BackgroundNoticeScreenState();
}

class _BackgroundNoticeScreenState extends State<BackgroundNoticeScreen> {
  int _mode = 0;

  @override
  Widget build(BuildContext context) {
    final disguised = _mode == 1;
    return EmberScaffold(
      glows: const [
        Glow(color: Ember.deepWine, width: 380, height: 320, left: -120, top: -60),
        Glow(color: Ember.nightPlum, width: 300, height: 280, opacity: 0.85, right: -120, bottom: 120),
      ],
      child: FillScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SakTopBar(),
            const SizedBox(height: 16),
            const ScreenTitle(
              'One notification\nstays on',
              subtitle: 'To keep listening with the screen off, Android makes Sakshya show a notification. It sits quietly at the top.',
            ),
            const SizedBox(height: 16),
            SakSegmented(options: const ['Normal', 'With disguise'], index: _mode, onChanged: (i) => setState(() => _mode = i)),
            const SizedBox(height: 16),
            ExcludeSemantics(
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: const LinearGradient(begin: Alignment(-0.6, -1), end: Alignment(0.6, 1), colors: [Color(0xFF2A1A22), Color(0xFF120B0E)], stops: [0, 0.7]),
                  border: Border.all(color: const Color(0x14FFFFFF)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(6, 0, 6, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text('9:41', style: TextStyle(fontFamily: SakFont.display, fontSize: 30, fontWeight: FontWeight.w600, color: Color(0xE6F4ECEE))),
                          Spacer(),
                          Text('Notification shade', style: TextStyle(fontFamily: SakFont.body, fontSize: 12, color: Color(0x8CF4ECEE))),
                        ],
                      ),
                    ),
                    AnimatedSwitcher(
                      duration: SakMotion.of(context, const Duration(milliseconds: 420)),
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(begin: const Offset(0, -0.12), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: SakMotion.enter)),
                          child: child,
                        ),
                      ),
                      child: _NotificationMock(key: ValueKey(disguised), disguised: disguised),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _Tip(1, 'Leave it there. It is how you know protection is on.'),
            const SizedBox(height: 12),
            const _Tip(2, 'If it ever disappears, open Sakshya once. Protection starts again.'),
            const SizedBox(height: 12),
            const _Tip(3, 'Using the calculator disguise? Next, hide the real name.'),
            const Spacer(),
            const SizedBox(height: 24),
            SakButton(
              label: widget.fromGuide ? 'Done' : 'Next',
              style: SakButtonStyle.pearl,
              onPressed: () => widget.fromGuide
                  ? Navigator.pop(context)
                  : SetupFlow.next(context, const HideNotificationScreen()),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationMock extends StatelessWidget {
  const _NotificationMock({super.key, required this.disguised});
  final bool disguised;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xEB281E22),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0x1AFFFFFF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: disguised ? const Color(0xFF5F7A8A) : null,
                      gradient: disguised ? null : const LinearGradient(colors: [Ember.emberStart, Color(0xFF3A1320)]),
                    ),
                    child: Icon(disguised ? Icons.calculate_outlined : Icons.shield_outlined, size: 11, color: Colors.white),
                  ),
                  const SizedBox(width: 8),
                  if (disguised)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFFF8FA3), width: 1.5),
                      ),
                      child: const Text('Sakshya', style: TextStyle(fontFamily: SakFont.body, fontSize: 12, fontWeight: FontWeight.w600, color: Ember.roseSoft)),
                    )
                  else
                    const Text('Sakshya', style: TextStyle(fontFamily: SakFont.body, fontSize: 12, color: Color(0xB3F4ECEE))),
                  const Text(' · now', style: TextStyle(fontFamily: SakFont.body, fontSize: 12, color: Color(0xB3F4ECEE))),
                ],
              ),
              const SizedBox(height: 6),
              Text(disguised ? 'Calculator' : 'Sakshya is protecting you', style: context.type.titleSmall),
              const SizedBox(height: 2),
              Text(
                disguised ? 'New calculations? The numbers miss you.' : 'Listening for danger. Recordings are sealed automatically.',
                style: context.type.bodySmall?.copyWith(color: const Color(0xBFF4ECEE)),
              ),
            ],
          ),
        ),
        if (disguised)
          const Padding(
            padding: EdgeInsets.only(top: 8, left: 6),
            child: Text('Android still prints the real name here.', style: TextStyle(fontFamily: SakFont.body, fontSize: 12, color: Ember.roseSoft)),
          ),
      ],
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip(this.n, this.text);
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StepNumber(n, size: 24),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: context.type.bodyMedium?.copyWith(fontSize: 14, height: 20 / 14, color: const Color(0xD9F4ECEE)))),
      ],
    );
  }
}

/// Setup 5: turning off the disguised notification's channel, which only
/// the user can do.
class HideNotificationScreen extends StatefulWidget {
  const HideNotificationScreen({super.key, this.fromGuide = false});
  final bool fromGuide;

  @override
  State<HideNotificationScreen> createState() => _HideNotificationScreenState();
}

class _HideNotificationScreenState extends State<HideNotificationScreen> with WidgetsBindingObserver, _RefreshOnResume {
  bool? _visible;

  @override
  Future<void> refresh() async {
    final visible = await ProtectionService.disguisedNotificationVisible();
    if (mounted) setState(() => _visible = visible);
  }

  void _next() {
    if (widget.fromGuide) {
      Navigator.pop(context);
    } else {
      SetupFlow.next(context, const BatteryScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidden = _visible == false;
    return EmberScaffold(
      glows: const [
        Glow(color: Ember.deepWine, width: 360, height: 300, right: -140, top: -80),
        Glow(color: Ember.nightPlum, width: 340, height: 300, opacity: 0.85, left: -160, bottom: 80),
      ],
      child: FillScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SakTopBar(
              trailing: Text('Only for the disguise', style: context.type.labelMedium),
            ),
            const SizedBox(height: 16),
            const ScreenTitle('Hide the real name', subtitle: "Android won't let an app do this itself. It takes you ten seconds, once."),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 6),
              child: Text('SETTINGS › SAKSHYA › NOTIFICATIONS', style: TextStyle(fontFamily: SakFont.mono, fontSize: 11, letterSpacing: 1.2, color: Color(0x99F4ECEE))),
            ),
            Glass(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(SakRadius.group),
                child: Column(
                  children: [
                    const _ChannelRow(title: 'Running in background', hint: 'Leave this one as it is', on: true, dim: true),
                    const Divider(height: 1, color: Ember.hairline),
                    Semantics(
                      button: true,
                      label: hidden ? 'Background notifications are off' : 'Open settings to turn off Background',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: ProtectionService.openDisguisedNotificationSettings,
                        child: AnimatedContainer(
                          duration: SakMotion.of(context, SakMotion.standard),
                          color: hidden ? Colors.transparent : const Color(0x388E1B32),
                          child: _ChannelRow(
                            title: 'Background',
                            hint: hidden ? 'Off. The notification is hidden' : 'Turn this off',
                            hintColor: hidden ? Ember.sealed : Ember.roseSoft,
                            on: !hidden,
                            flag: !hidden,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const _Tip(1, 'Tap Open settings below.'),
            const SizedBox(height: 12),
            const _Tip(2, 'Switch off “Background”. Leave the other switch on.'),
            const SizedBox(height: 12),
            const _Tip(3, 'Come back. Listening keeps working, and the notification no longer shows.'),
            const Spacer(),
            const SizedBox(height: 24),
            AnimatedSwitcher(
              duration: SakMotion.of(context, SakMotion.standard),
              child: hidden
                  ? SakButton(key: const ValueKey('done'), label: widget.fromGuide ? 'Done' : 'Next', style: SakButtonStyle.pearl, onPressed: _next)
                  : SakButton(
                      key: const ValueKey('open'),
                      label: 'Open settings',
                      trailingIcon: Icons.open_in_new_rounded,
                      onPressed: ProtectionService.openDisguisedNotificationSettings,
                    ),
            ),
            if (!hidden)
              TextButton(
                onPressed: _next,
                child: Text(
                  widget.fromGuide ? 'Not now' : "I won't use the disguise. Skip",
                  style: const TextStyle(color: Color(0xBFF4ECEE)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    required this.title,
    required this.hint,
    required this.on,
    this.hintColor = const Color(0x99F4ECEE),
    this.dim = false,
    this.flag = false,
  });

  final String title;
  final String hint;
  final bool on;
  final Color hintColor;
  final bool dim;
  final bool flag;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 60),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: context.type.bodyLarge?.copyWith(fontWeight: dim ? FontWeight.w400 : FontWeight.w600)),
                  Text(hint, style: TextStyle(fontFamily: SakFont.body, fontSize: 12, fontWeight: dim ? FontWeight.w400 : FontWeight.w600, color: hintColor)),
                ],
              ),
            ),
            ExcludeSemantics(
              child: Opacity(
                opacity: dim ? 0.55 : 1,
                child: _Flagged(flag: flag, child: IgnorePointer(child: SakSwitch(value: on, onChanged: (_) {}, activeColor: const Color(0xFF7FA7C9)))),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A soft pink pulse around whatever the user should touch.
class _Flagged extends StatefulWidget {
  const _Flagged({required this.flag, required this.child});
  final bool flag;
  final Widget child;

  @override
  State<_Flagged> createState() => _FlaggedState();
}

class _FlaggedState extends State<_Flagged> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Flagged old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.flag && !SakMotion.reduced(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.flag) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value < 0.5 ? _c.value * 2 : (1 - _c.value) * 2;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: [BoxShadow(color: Color.fromRGBO(255, 143, 163, 0.6 * (1 - t)), spreadRadius: 7 * t)],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Setup 6: keeping battery savers from closing Sakshya.
class BatteryScreen extends StatefulWidget {
  const BatteryScreen({super.key, this.fromGuide = false});
  final bool fromGuide;

  @override
  State<BatteryScreen> createState() => _BatteryScreenState();
}

class _BatteryScreenState extends State<BatteryScreen> with WidgetsBindingObserver, _RefreshOnResume {
  bool _exempt = false;
  int _maker = 0;

  static const _makers = [
    (
      'Vivo',
      ['Settings', 'Battery', 'Background power consumption management', 'Sakshya', 'Allow'],
      'Also lock it in Recent apps, so cleaning recents never closes it.',
    ),
    (
      'Samsung',
      ['Settings', 'Apps', 'Sakshya', 'Battery', 'Unrestricted'],
      'In Battery › Background usage limits, make sure Sakshya is not under Sleeping or Deep sleeping apps.',
    ),
    (
      'Other',
      ['Settings', 'Apps', 'Sakshya', 'App battery usage', 'Unrestricted'],
      'Names differ by brand. Look for battery, then “unrestricted” or “allow background”.',
    ),
  ];

  @override
  Future<void> refresh() async {
    final exempt = await Permission.ignoreBatteryOptimizations.isGranted;
    if (mounted) setState(() => _exempt = exempt);
  }

  Future<void> _openBattery() async {
    if (!_exempt) {
      await Hive.box('vault_box').put(SetupFlow.batteryAskedKey, true);
      await Permission.ignoreBatteryOptimizations.request();
      await refresh();
    } else {
      await openAppSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final maker = _makers[_maker];
    return EmberScaffold(
      glows: const [
        Glow(color: Ember.deepWine, width: 380, height: 320, left: -140, top: -80),
        Glow(color: Ember.nightPlum, width: 320, height: 300, opacity: 0.85, right: -140, bottom: 140),
      ],
      child: FillScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SakTopBar(),
            const SizedBox(height: 16),
            const ScreenTitle("Don't let it sleep", subtitle: 'Battery savers close apps in the background. That would stop listening.'),
            const SizedBox(height: 16),
            ExcludeSemantics(
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF221A1D),
                  borderRadius: BorderRadius.circular(SakRadius.card),
                  border: Border.all(color: const Color(0x1AFFFFFF)),
                  boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 50, offset: Offset(0, 24))],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Let app always run in background?', style: context.type.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Allowing Sakshya to always run in the background may reduce battery life.',
                      style: context.type.bodySmall?.copyWith(color: const Color(0xB8F4ECEE)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Text('Deny', style: TextStyle(fontFamily: SakFont.body, fontSize: 14, fontWeight: FontWeight.w600, color: Color(0x99F4ECEE))),
                        ),
                        const SizedBox(width: 8),
                        _Flagged(
                          flag: !_exempt,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(color: Ember.ink, borderRadius: BorderRadius.circular(999)),
                            child: const Text('Allow', style: TextStyle(fontFamily: SakFont.body, fontSize: 14, fontWeight: FontWeight.w700, color: Ember.onPearl)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _exempt
                  ? const Row(
                      children: [
                        Icon(Icons.check_circle_rounded, size: 16, color: Ember.sealed),
                        SizedBox(width: 6),
                        Text('Allowed. Android will leave Sakshya running.', style: TextStyle(fontFamily: SakFont.body, fontSize: 13, fontWeight: FontWeight.w600, color: Ember.sealed)),
                      ],
                    )
                  : const Text('Tap Allow when Android asks.', style: TextStyle(fontFamily: SakFont.body, fontSize: 13, fontWeight: FontWeight.w600, color: Ember.roseSoft)),
            ),
            const SizedBox(height: 18),
            Text('Then, depending on your phone', style: context.type.titleSmall),
            const SizedBox(height: 10),
            SakSegmented(options: [for (final m in _makers) m.$1], index: _maker, onChanged: (i) => setState(() => _maker = i)),
            const SizedBox(height: 10),
            Glass(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: AnimatedSwitcher(
                duration: SakMotion.of(context, const Duration(milliseconds: 300)),
                child: Column(
                  key: ValueKey(_maker),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          for (var i = 0; i < maker.$2.length; i++) ...[
                            if (i > 0) const TextSpan(text: ' › '),
                            TextSpan(
                              text: maker.$2[i],
                              style: maker.$2[i] == 'Sakshya' || i == maker.$2.length - 1
                                  ? const TextStyle(color: Ember.roseSoft, fontWeight: FontWeight.w500)
                                  : null,
                            ),
                          ],
                        ],
                      ),
                      style: const TextStyle(fontFamily: SakFont.mono, fontSize: 13, height: 21 / 13, color: Ember.ink),
                    ),
                    const SizedBox(height: 10),
                    Text(maker.$3, style: context.type.bodySmall?.copyWith(color: const Color(0xB8F4ECEE))),
                  ],
                ),
              ),
            ),
            const Spacer(),
            const SizedBox(height: 24),
            SakButton(
              label: _exempt ? 'Open app settings' : 'Open battery settings',
              style: SakButtonStyle.glass,
              height: 52,
              fontSize: 16,
              trailingIcon: Icons.open_in_new_rounded,
              onPressed: _openBattery,
            ),
            const SizedBox(height: 10),
            SakButton(
              label: widget.fromGuide ? 'Done' : 'Finish setup',
              style: SakButtonStyle.pearl,
              onPressed: () => widget.fromGuide ? Navigator.pop(context) : SetupFlow.finish(context),
            ),
          ],
        ),
      ),
    );
  }
}
