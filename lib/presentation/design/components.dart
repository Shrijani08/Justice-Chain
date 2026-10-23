import 'package:flutter/material.dart';

import 'tokens.dart';

/// Scales down the moment a finger lands (pointer-down, not tap-up) and
/// springs back on release, so every control answers before the gesture
/// is even recognised. The action itself stays with [child]'s own handler.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.enabled = true, this.scale = 0.97});

  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
    reverseDuration: SakMotion.standard,
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent _) {
    if (widget.enabled && !SakMotion.reduced(context)) _press.forward();
  }

  void _up([PointerEvent? _]) => _press.reverse();

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: AnimatedBuilder(
        animation: _press,
        builder: (context, child) {
          // Spring back from wherever the press currently is.
          final t = _press.status == AnimationStatus.reverse
              ? SakMotion.spring.flipped.transform(_press.value)
              : _press.value;
          return Transform.scale(scale: 1 - (1 - widget.scale) * t, child: child);
        },
        child: widget.child,
      ),
    );
  }
}

enum SakButtonStyle { filled, tinted, plain, danger, dangerTinted }

/// The one button. Full width by default, 52 pt tall, label in Title Case.
class SakButton extends StatelessWidget {
  const SakButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = SakButtonStyle.filled,
    this.loading = false,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final SakButtonStyle style;
  final bool loading;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    final (bg, fg) = switch (style) {
      SakButtonStyle.filled => (c.accent, c.onAccent),
      SakButtonStyle.tinted => (c.accentSoft, c.accent),
      SakButtonStyle.plain => (Colors.transparent, c.accent),
      SakButtonStyle.danger => (c.danger, c.onDanger),
      SakButtonStyle.dangerTinted => (c.dangerSoft, c.danger),
    };
    final enabled = onPressed != null && !loading;

    final content = AnimatedSwitcher(
      duration: SakMotion.of(context, SakMotion.quick),
      child: loading
          ? SizedBox(
              key: const ValueKey('loading'),
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
            )
          : Row(
              key: const ValueKey('label'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: SakSpace.sm)],
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: context.type.labelLarge?.copyWith(color: fg),
                  ),
                ),
              ],
            ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: loading ? '$label, in progress' : null,
      child: Pressable(
        enabled: enabled,
        child: AnimatedOpacity(
          duration: SakMotion.of(context, SakMotion.quick),
          opacity: enabled || loading ? 1 : 0.45,
          child: Material(
            color: bg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(SakRadius.control)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onPressed : null,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: 52, minWidth: expand ? double.infinity : 0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Center(widthFactor: expand ? null : 1, child: content),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A collapsing large title over grouped content, like a settings page.
class SakPage extends StatelessWidget {
  const SakPage({
    super.key,
    required this.title,
    required this.slivers,
    this.actions,
    this.large = true,
  });

  final String title;
  final List<Widget> slivers;
  final List<Widget>? actions;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    final appBar = large
        ? SliverAppBar.large(
            title: Text(title),
            actions: actions,
            backgroundColor: c.background,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            centerTitle: true,
          )
        : SliverAppBar(
            title: Text(title),
            actions: actions,
            pinned: true,
            backgroundColor: c.background,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
          );
    return Scaffold(
      backgroundColor: c.background,
      body: CustomScrollView(
        slivers: [
          appBar,
          ...slivers,
          const SliverToBoxAdapter(child: SafeArea(top: false, child: SizedBox(height: SakSpace.xl))),
        ],
      ),
    );
  }
}

/// Small caps-free header above a group, with an optional footer below.
class SakGroup extends StatelessWidget {
  const SakGroup({super.key, this.header, this.footer, required this.children});

  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    return Padding(
      padding: const EdgeInsets.fromLTRB(SakSpace.lg, SakSpace.sm, SakSpace.lg, SakSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(SakSpace.lg, 0, SakSpace.lg, SakSpace.sm),
              child: Semantics(
                header: true,
                child: Text(header!, style: context.type.labelMedium?.copyWith(color: c.inkSecondary)),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(SakRadius.card),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(SakRadius.card),
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) Divider(height: 0.5, indent: 60, color: c.separator),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(SakSpace.lg, SakSpace.sm, SakSpace.lg, 0),
              child: Text(footer!, style: context.type.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// A rounded square holding a symbol, tinted by its role.
class SakIconTile extends StatelessWidget {
  const SakIconTile({super.key, required this.icon, this.color, this.size = 32});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.sak.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(icon, size: size * 0.58, color: tint),
    );
  }
}

/// One row in a [SakGroup]: symbol, title, optional detail, chevron when it
/// navigates.
class SakRow extends StatelessWidget {
  const SakRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.leading,
    this.trailing,
    this.onTap,
    this.chevron = true,
    this.enabled = true,
    this.titleStyle,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final bool enabled;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    final active = enabled && onTap != null;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SakSpace.lg, vertical: SakSpace.md),
        child: Row(
          children: [
            if (leading != null)
              leading!
            else if (icon != null)
              SakIconTile(icon: icon!, color: enabled ? iconColor : c.inkTertiary),
            if (leading != null || icon != null) const SizedBox(width: SakSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: (titleStyle ?? context.type.bodyLarge)
                        ?.copyWith(color: enabled ? null : c.inkTertiary),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: context.type.bodySmall),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: SakSpace.sm), trailing!],
            if (active && chevron) ...[
              const SizedBox(width: SakSpace.xs),
              Icon(Icons.chevron_right_rounded, color: c.inkTertiary, size: 22),
            ],
          ],
        ),
      ),
    );

    if (!active) return row;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// A coloured capsule naming a state: "Listening", "Sealed", "Recording".
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color, this.icon, this.pulsing = false});

  final String label;
  final Color color;
  final IconData? icon;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: SakMotion.of(context, SakMotion.standard),
      curve: SakMotion.spring,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 14, color: color)
          else
            _Dot(color: color, pulsing: pulsing),
          const SizedBox(width: 6),
          Text(label, style: context.type.labelMedium?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color, required this.pulsing});
  final Color color;
  final bool pulsing;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Dot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.pulsing && !SakMotion.reduced(context)) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(width: 7, height: 7, decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle)),
    );
  }
}

enum NoticeTone { info, warning, danger, success }

/// An inline message inside the content, used instead of an alert.
class SakNotice extends StatelessWidget {
  const SakNotice({super.key, required this.message, this.tone = NoticeTone.info, this.title});

  final String message;
  final String? title;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    final (fg, bg, icon) = switch (tone) {
      NoticeTone.info => (c.accent, c.accentSoft, Icons.info_rounded),
      NoticeTone.warning => (c.warning, c.warningSoft, Icons.warning_rounded),
      NoticeTone.danger => (c.danger, c.dangerSoft, Icons.error_rounded),
      NoticeTone.success => (c.success, c.successSoft, Icons.verified_rounded),
    };
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(SakSpace.lg),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(SakRadius.card)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: fg, size: 22),
            const SizedBox(width: SakSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(title!, style: context.type.titleSmall),
                    const SizedBox(height: 2),
                  ],
                  Text(message, style: context.type.bodyMedium?.copyWith(color: c.ink)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The empty state: a symbol, one line saying what goes here, and how.
class SakEmptyState extends StatelessWidget {
  const SakEmptyState({super.key, required this.icon, required this.title, required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SakSpace.xxl, vertical: SakSpace.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: c.accentSoft, shape: BoxShape.circle),
            child: Icon(icon, size: 34, color: c.accent),
          ),
          const SizedBox(height: SakSpace.lg),
          Text(title, textAlign: TextAlign.center, style: context.type.titleMedium),
          const SizedBox(height: SakSpace.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: context.type.bodyMedium?.copyWith(color: c.inkSecondary),
          ),
        ],
      ),
    );
  }
}

/// A hash, ID or code set in monospace. Hashes read in groups of four.
class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key, this.style, this.selectable = false, this.textAlign, this.maxLines});

  final String text;
  final TextStyle? style;
  final bool selectable;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final s = (context.type.bodyMedium ?? const TextStyle()).merge(style).copyWith(
          fontFamily: SakMono.family,
          fontFamilyFallback: SakMono.fallback,
          letterSpacing: style?.letterSpacing ?? 0.2,
        );
    return selectable
        ? SelectableText(text, style: s, textAlign: textAlign, maxLines: maxLines)
        : Text(text, style: s, textAlign: textAlign, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
  }
}

/// Fades and lifts content into place once, staggered by [index]. With
/// reduced motion it simply appears.
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (SakMotion.reduced(context)) return child;
    final delay = (index * 0.08).clamp(0.0, 0.5);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: SakMotion.slow + Duration(milliseconds: (index * 60).clamp(0, 300)),
      curve: Interval(delay, 1, curve: SakMotion.spring),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}

/// The app's mark on first-run screens: a seal, because everything Sakshya
/// records is sealed the moment it stops.
class SealMark extends StatelessWidget {
  const SealMark({super.key, this.icon = Icons.verified_user_rounded});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    return ExcludeSemantics(
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.surface,
          border: Border.all(color: c.accentSoft, width: 6),
          boxShadow: [
            BoxShadow(color: c.accent.withValues(alpha: 0.16), blurRadius: 28, offset: const Offset(0, 10)),
          ],
        ),
        child: Icon(icon, size: 42, color: c.accent),
      ),
    );
  }
}

/// A modal progress card ("Decrypting and verifying…") for work the user
/// has to wait on.
Future<void> showSakProgress(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.6)),
            const SizedBox(width: SakSpace.lg),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  );
}
