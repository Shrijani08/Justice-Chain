import 'package:flutter/cupertino.dart';
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

/// One soft light behind a screen. The canvas draws these as blurred
/// ellipses; a radial fade gives the same look without a blur pass.
class Glow {
  const Glow({
    required this.color,
    required this.width,
    required this.height,
    this.opacity = 0.8,
    this.left,
    this.top,
    this.right,
    this.bottom,
  });

  final Color color;
  final double width;
  final double height;
  final double opacity;
  final double? left;
  final double? top;
  final double? right;
  final double? bottom;
}

/// The near-black ground with its glows, filling whatever it is given.
class EmberBackground extends StatelessWidget {
  const EmberBackground({super.key, this.color = Ember.ground, this.glows = const []});

  final Color color;
  final List<Glow> glows;

  // How far the canvas's 70 px blur spreads light past the shape's edge.
  static const double _spread = 70;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final g in glows)
            Positioned(
              left: g.left == null ? null : g.left! - _spread,
              top: g.top == null ? null : g.top! - _spread,
              right: g.right == null ? null : g.right! - _spread,
              bottom: g.bottom == null ? null : g.bottom! - _spread,
              width: g.width + _spread * 2,
              height: g.height + _spread * 2,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        g.color.withValues(alpha: g.opacity),
                        g.color.withValues(alpha: g.opacity * 0.72),
                        g.color.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.42, 1],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A full screen on the Ember ground: glows behind, content in the safe
/// area with the canvas's 20 px gutters.
class EmberScaffold extends StatelessWidget {
  const EmberScaffold({
    super.key,
    required this.child,
    this.background = Ember.ground,
    this.glows = const [],
    this.padding = const EdgeInsets.fromLTRB(SakSpace.gutter, SakSpace.md, SakSpace.gutter, SakSpace.xl),
    this.resizeToAvoidBottomInset = true,
  });

  final Widget child;
  final Color background;
  final List<Glow> glows;
  final EdgeInsets padding;
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: background,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      body: Stack(
        fit: StackFit.expand,
        children: [
          EmberBackground(color: background, glows: glows),
          SafeArea(child: Padding(padding: padding, child: child)),
        ],
      ),
    );
  }
}

/// Fills the space it gets and scrolls when the content is taller, so a
/// screen laid out with Spacer still works on a short phone.
class FillScroll extends StatelessWidget {
  const FillScroll({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(child: child),
        ),
      ),
    );
  }
}

/// Frosted glass: white 6% with a 12% hairline.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = SakRadius.group,
    this.padding,
    this.color = Ember.glass,
    this.borderColor = Ember.glassBorder,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor),
      ),
      child: child,
    );
  }
}

enum SakButtonStyle { ember, pearl, glass, destructive, plain }

/// The one button: a pill, 58 tall by default.
/// [SakButtonStyle.ember] is the primary action, [SakButtonStyle.pearl]
/// confirms, [SakButtonStyle.glass] is secondary.
class SakButton extends StatelessWidget {
  const SakButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailingIcon,
    this.style = SakButtonStyle.ember,
    this.loading = false,
    this.expand = true,
    this.height = 58,
    this.fontSize = 17,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final IconData? trailingIcon;
  final SakButtonStyle style;
  final bool loading;
  final bool expand;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final fg = switch (style) {
      SakButtonStyle.pearl => Ember.onPearl,
      SakButtonStyle.plain => Ember.ink2,
      _ => const Color(0xFFFFFFFF),
    };
    final decoration = switch (style) {
      SakButtonStyle.ember => BoxDecoration(
          gradient: Ember.emberGradient,
          borderRadius: BorderRadius.circular(SakRadius.pill),
          border: Border.all(color: Ember.emberEdge),
          boxShadow: const [BoxShadow(color: Color(0x805A0F22), blurRadius: 30, offset: Offset(0, 14))],
        ),
      SakButtonStyle.pearl => BoxDecoration(
          gradient: Ember.pearlGradient,
          borderRadius: BorderRadius.circular(SakRadius.pill),
        ),
      SakButtonStyle.glass => BoxDecoration(
          color: const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(SakRadius.pill),
          border: Border.all(color: Ember.glassBorder),
        ),
      SakButtonStyle.destructive => BoxDecoration(
          color: Ember.destructive,
          borderRadius: BorderRadius.circular(SakRadius.pill),
        ),
      SakButtonStyle.plain => const BoxDecoration(),
    };
    final weight = style == SakButtonStyle.glass || style == SakButtonStyle.plain ? FontWeight.w600 : FontWeight.w700;

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
                if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 10)],
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: TextStyle(fontFamily: SakFont.body, fontSize: fontSize, fontWeight: weight, color: fg, height: 1.2),
                  ),
                ),
                if (trailingIcon != null) ...[const SizedBox(width: 8), Icon(trailingIcon, size: 18, color: fg)],
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
          opacity: enabled || loading ? 1 : 0.4,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? onPressed : null,
            child: Container(
              height: height,
              constraints: BoxConstraints(minWidth: expand ? double.infinity : 0),
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: decoration,
              alignment: Alignment.center,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// A 44 pt glass circle holding one symbol: back, add, help.
class CircleButton extends StatelessWidget {
  const CircleButton({super.key, required this.icon, required this.label, required this.onTap, this.badge = false});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: Ember.glass,
              shape: BoxShape.circle,
              border: Border.fromBorderSide(BorderSide(color: Ember.glassBorder)),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, size: 20, color: Ember.ink),
                if (badge)
                  Positioned(
                    top: 10,
                    right: 11,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5A6E),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF1A0F12), width: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Back on the left, a title in the middle, an optional action on the right.
class SakTopBar extends StatelessWidget {
  const SakTopBar({super.key, this.title, this.center, this.trailing, this.onBack, this.showBack = true});

  final String? title;

  /// Shown in the middle instead of [title].
  final Widget? center;
  final Widget? trailing;
  final VoidCallback? onBack;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: center == null ? 44 : null,
      child: Row(
        children: [
          if (showBack)
            CircleButton(
              icon: Icons.chevron_left_rounded,
              label: 'Back',
              onTap: onBack ?? () => Navigator.maybePop(context),
            )
          else
            const SizedBox(width: 44),
          Expanded(
            child: center != null
                ? Center(child: center)
                : title == null
                ? const SizedBox()
                : Text(
                    title!,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.titleMedium,
                  ),
          ),
          trailing ?? const SizedBox(width: 44),
        ],
      ),
    );
  }
}

/// A large title with an optional line under it.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.subtitle, this.size = 34});

  final String title;
  final String? subtitle;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: context.type.displayMedium?.copyWith(fontSize: size, height: (size + 4) / size),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(subtitle!, style: context.type.bodyMedium?.copyWith(fontSize: 14, height: 20 / 14, color: const Color(0xB8F4ECEE))),
        ],
      ],
    );
  }
}

/// A rounded square holding a symbol, tinted by its role.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.color = Ember.ink, this.background, this.size = 34});

  final IconData icon;
  final Color color;
  final Color? background;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? (color == Ember.ink ? const Color(0x1AFFFFFF) : color.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(icon, size: size * 0.53, color: color),
    );
  }
}

/// Small grey header above a group.
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Semantics(header: true, child: Text(text, style: context.type.labelMedium)),
    );
  }
}

/// Rows on one glass panel, split by hairlines.
class SakGroup extends StatelessWidget {
  const SakGroup({super.key, this.header, this.footer, required this.children});

  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null) GroupLabel(header!),
        Glass(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(SakRadius.group),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: Ember.hairline),
                  children[i],
                ],
              ],
            ),
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(footer!, style: context.type.labelSmall?.copyWith(color: Ember.ink3)),
          ),
      ],
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
    this.subtitleColor,
    this.icon,
    this.iconColor = Ember.ink,
    this.leading,
    this.trailing,
    this.value,
    this.onTap,
    this.chevron = true,
    this.enabled = true,
    this.titleStyle,
  });

  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final IconData? icon;
  final Color iconColor;
  final Widget? leading;
  final Widget? trailing;
  final String? value;
  final VoidCallback? onTap;
  final bool chevron;
  final bool enabled;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (leading != null)
              leading!
            else if (icon != null)
              IconTile(icon: icon!, color: enabled ? iconColor : Ember.ink3),
            if (leading != null || icon != null) const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: (titleStyle ?? context.type.bodyLarge)?.copyWith(color: enabled ? null : Ember.ink3),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: context.type.labelSmall?.copyWith(color: subtitleColor ?? Ember.ink2)),
                  ],
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 8),
              Text(value!, style: context.type.bodyMedium?.copyWith(color: Ember.ink2)),
            ],
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            if (active && chevron) ...[
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, color: Color(0x80F4ECEE), size: 22),
            ],
          ],
        ),
      ),
    );

    if (!active) return row;
    return Semantics(
      button: true,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: row),
    );
  }
}

/// The iOS-style switch from the canvas: green when on.
class SakSwitch extends StatelessWidget {
  const SakSwitch({super.key, required this.value, required this.onChanged, this.activeColor = Ember.sealed});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    return CupertinoSwitch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: activeColor,
      inactiveTrackColor: const Color(0x29FFFFFF),
    );
  }
}

/// A coloured capsule naming a state: "Ready", "Anchored on ledger".
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(SakRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 5)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: SakFont.body, fontSize: 12, fontWeight: FontWeight.w600, color: color, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// A dot that breathes while something is live.
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, required this.color, this.size = 7, this.period = const Duration(milliseconds: 1600)});
  final Color color;
  final double size;
  final Duration period;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (SakMotion.reduced(context)) {
      _c.value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
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
      opacity: Tween(begin: 1.0, end: 0.35).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

enum NoticeTone { info, attention, sealed, alarm }

/// An inline message inside the content, used instead of an alert.
class SakNotice extends StatelessWidget {
  const SakNotice({super.key, required this.message, this.tone = NoticeTone.attention, this.title, this.icon});

  final String message;
  final String? title;
  final NoticeTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (fg, defaultIcon) = switch (tone) {
      NoticeTone.info => (Ember.rose, Icons.info_outline_rounded),
      NoticeTone.attention => (Ember.attention, Icons.warning_amber_rounded),
      NoticeTone.sealed => (Ember.sealed, Icons.verified_user_outlined),
      NoticeTone.alarm => (Ember.alertText, Icons.error_outline_rounded),
    };
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: fg.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: fg.withValues(alpha: 0.28)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon ?? defaultIcon, color: fg, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(title!, style: context.type.titleSmall),
                    const SizedBox(height: 3),
                  ],
                  Text(message, style: context.type.bodySmall?.copyWith(color: const Color(0xC7F4ECEE))),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SakSpace.xl, vertical: SakSpace.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(center: Alignment(-0.3, -0.4), colors: [Color(0xFF3A1520), Color(0xFF14070B)]),
              border: Border.fromBorderSide(BorderSide(color: Color(0x24FFFFFF))),
            ),
            child: Icon(icon, size: 32, color: Ember.blush),
          ),
          const SizedBox(height: SakSpace.lg),
          Text(title, textAlign: TextAlign.center, style: context.type.titleMedium),
          const SizedBox(height: SakSpace.sm),
          Text(message, textAlign: TextAlign.center, style: context.type.bodyMedium?.copyWith(color: Ember.ink2)),
        ],
      ),
    );
  }
}

/// A hash, ID or code set in monospace.
class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key, this.style, this.selectable = false, this.textAlign, this.maxLines});

  final String text;
  final TextStyle? style;
  final bool selectable;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final s = const TextStyle(fontSize: 13, color: Ember.ink, height: 1.4).merge(style).copyWith(
          fontFamily: SakMono.family,
          fontFamilyFallback: SakMono.fallback,
          letterSpacing: style?.letterSpacing ?? 0.4,
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
    final delay = (index * 0.1).clamp(0.0, 0.6);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: SakMotion.slow + Duration(milliseconds: (index * 80).clamp(0, 480)),
      curve: Interval(delay, 1, curve: SakMotion.enter),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}

/// A person's initial on their colour.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 44, this.muted = false});

  final String name;
  final double size;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = Ember.avatarFor(name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: muted ? const Color(0x1FFFFFFF) : null,
        gradient: muted ? null : LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          fontFamily: SakFont.display,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.39,
          color: muted ? Ember.ink2 : Ember.ink,
        ),
      ),
    );
  }
}

/// A numbered circle for steps.
class StepNumber extends StatelessWidget {
  const StepNumber(this.n, {super.key, this.size = 26});
  final int n;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0x738E1B32),
        border: Border.all(color: const Color(0x4DD99AAB)),
      ),
      child: Text(
        '$n',
        style: TextStyle(fontFamily: SakFont.display, fontSize: size * 0.5, fontWeight: FontWeight.w700, color: Ember.ink),
      ),
    );
  }
}

/// Page position as dots, the current one stretched.
class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Step ${index + 1} of $count',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            AnimatedContainer(
              duration: SakMotion.of(context, SakMotion.standard),
              curve: SakMotion.spring,
              width: i == index ? 26 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i == index ? Ember.ink : const Color(0x40F4ECEE),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A glass segmented control: the chosen option on a pearl pill.
class SakSegmented extends StatelessWidget {
  const SakSegmented({super.key, required this.options, required this.index, required this.onChanged});

  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: SakRadius.pill,
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: Semantics(
                selected: i == index,
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: SakMotion.of(context, const Duration(milliseconds: 240)),
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == index ? Ember.ink : Colors.transparent,
                      borderRadius: BorderRadius.circular(SakRadius.pill),
                    ),
                    child: Text(
                      options[i],
                      style: TextStyle(
                        fontFamily: SakFont.body,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: i == index ? Ember.onPearl : const Color(0xCCF4ECEE),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
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
            Expanded(child: Text(message, style: const TextStyle(color: Ember.ink, fontSize: 15))),
          ],
        ),
      ),
    ),
  );
}

/// A sheet that rises from the bottom on the canvas's wine gradient.
Future<T?> showSakSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.vertical(top: Radius.circular(SakRadius.sheet)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF24171B), Color(0xFF160E11)],
          ),
          border: Border(top: BorderSide(color: Color(0x24FFFFFF))),
          boxShadow: [BoxShadow(color: Color(0x99000000), blurRadius: 60, offset: Offset(0, -20))],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 5,
                    decoration: BoxDecoration(color: const Color(0x47FFFFFF), borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                const SizedBox(height: 18),
                builder(context),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Asks before something that can't be undone. Returns true on confirm.
Future<bool> confirmSak(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final ok = await showSakSheet<bool>(
    context,
    (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: context.type.headlineSmall),
        const SizedBox(height: 10),
        Text(message, style: context.type.bodyMedium?.copyWith(color: const Color(0xC7F4ECEE))),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: SakButton(
                label: 'Cancel',
                style: SakButtonStyle.glass,
                height: 54,
                fontSize: 16,
                onPressed: () => Navigator.pop(context, false),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SakButton(
                label: confirmLabel,
                style: destructive ? SakButtonStyle.destructive : SakButtonStyle.pearl,
                height: 54,
                fontSize: 16,
                onPressed: () => Navigator.pop(context, true),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return ok == true;
}

/// Text field styled like the canvas's inputs.
InputDecoration sakField({String? hint, String? error, Widget? suffix}) => InputDecoration(
      hintText: hint,
      errorText: error,
      counterText: '',
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );

/// The small label above a field.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: context.type.labelMedium?.copyWith(color: const Color(0xB8F4ECEE))),
    );
  }
}
