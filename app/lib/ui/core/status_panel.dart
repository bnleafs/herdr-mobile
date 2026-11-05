import 'dart:async';

import 'package:flutter/material.dart';

import 'press.dart';
import 'buttons.dart';
import 'motion.dart';
import 'theme.dart';

/// Shared look of [StatusPanel] and [StatusStrip]: the state's [Ds.wash].
/// Tint, not outline and not elevation; the colour is the state's colour,
/// never decoration.
abstract final class StatusTint {
  static const pad = Gap.md;

  static BoxDecoration decoration(Ds ds, Color color, {bool pressed = false}) => BoxDecoration(
    color: pressed ? ds.washPressed(color) : ds.wash(color),
    borderRadius: BorderRadius.circular(Radii.md),
  );
}

/// Flat tinted panel for a state that needs a sentence: a connection error, a
/// sign-in to approve, a test result. For a one-line state use [StatusStrip].
///
/// Layout: optional [icon], then [title] / [message] / [footer] stacked, and
/// an optional [trailing] action (a compact button) vertically centred.
class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.color,
    this.icon,
    this.title,
    this.message,
    this.mono = false,
    this.messageMaxLines,
    this.footer,
    this.trailing,
    this.liveRegion = false,
  });

  final Color color;
  final IconData? icon;
  final String? title;
  final String? message;

  /// Message in the terminal font (fingerprints, paths).
  final bool mono;
  final int? messageMaxLines;
  final Widget? footer;
  final Widget? trailing;

  /// Announce the panel when it appears (a state that arrives on its own).
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // A compact action is 44 high for touch; trim the panel's own padding so
    // the panel is no taller than it was around a 36 button.
    final vertical = trailing == null ? StatusTint.pad : Gap.sm;
    return Semantics(
      container: true,
      liveRegion: liveRegion,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(StatusTint.pad, vertical, trailing == null ? StatusTint.pad : Gap.sm, vertical),
        decoration: StatusTint.decoration(ds, color),
        child: Row(
          // A titled panel reads top-down (icon beside the title); a one-line
          // message with an action centres on the action.
          crossAxisAlignment: title != null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            if (icon != null)
              Padding(
                padding: EdgeInsets.only(right: Gap.md, top: title != null ? 1 + StatusTint.pad - vertical : 0),
                child: ExcludeSemantics(child: Icon(icon, size: 18, color: color)),
              ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: StatusTint.pad - vertical),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null)
                      Semantics(
                        header: true,
                        child: Text(title!, style: Type.answer.copyWith(color: ds.text)),
                      ),
                    if (message != null && message!.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: title == null ? 0 : 2),
                        child: Text(
                          message!,
                          maxLines: messageMaxLines,
                          overflow: messageMaxLines == null ? null : TextOverflow.ellipsis,
                          style: (mono ? Mono.base : Type.secondary).copyWith(color: ds.textSecondary),
                        ),
                      ),
                    if (footer != null)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.md),
                        child: footer,
                      ),
                  ],
                ),
              ),
            ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(left: Gap.sm),
                child: Semantics(container: true, child: trailing),
              ),
          ],
        ),
      ),
    );
  }
}

/// A one-line status: [leading] (a `LinkDot` or glyph), [title] with an optional
/// quieter [detail] after it, and an optional compact [action] (an
/// [AppButton] with `compact: true`). Same tint as [StatusPanel], ~48 high, so
/// several of them can stack above a list without pushing it off screen.
///
/// With [onTap] the whole strip is a button; the [action] stays its own.
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    required this.color,
    required this.title,
    this.detail,
    this.leading,
    this.action,
    this.onTap,
  });

  final Color color;
  final String title;
  final String? detail;
  final Widget? leading;
  final Widget? action;
  final VoidCallback? onTap;

  static const height = 48.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      container: true,
      child: PressBuilder(
        onTap: onTap,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: height),
          padding: EdgeInsets.fromLTRB(StatusTint.pad, 0, action == null ? StatusTint.pad : Gap.xs, 0),
          decoration: StatusTint.decoration(ds, color, pressed: pressed && onTap != null),
          child: Row(
            children: [
              if (leading != null) ...[ExcludeSemantics(child: leading), const SizedBox(width: 10)],
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  child: Text.rich(
                    TextSpan(
                      text: title,
                      style: Type.answer.copyWith(color: ds.text),
                      children: [
                        if (detail != null && detail!.isNotEmpty)
                          TextSpan(
                            text: '  $detail',
                            style: Type.secondary.copyWith(color: ds.textSecondary),
                          ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (action != null)
                Padding(
                  padding: const EdgeInsets.only(left: Gap.sm),
                  child: Semantics(container: true, child: action),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet inline loading indicator for transient states (connecting, updating,
/// reconnecting). It draws nothing for [delay] ([Dwell.connectGrace]) so a fast
/// connect never flashes it, then draws a small, neutral inline row with no banner.
/// The state is announced to assistive technologies immediately via [Semantics].
class SubtleLoadingIndicator extends StatefulWidget {
  const SubtleLoadingIndicator({super.key, required this.title, this.leading, this.delay = Dwell.connectGrace});

  final String title;
  final Widget? leading;
  final Duration delay;

  @override
  State<SubtleLoadingIndicator> createState() => _SubtleLoadingIndicatorState();
}

class _SubtleLoadingIndicatorState extends State<SubtleLoadingIndicator> {
  Timer? _timer;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(SubtleLoadingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.delay != widget.delay) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (widget.delay == Duration.zero) {
      _shown = true;
      return;
    }
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final child = !_shown
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.leading != null) ...[
                  ExcludeSemantics(child: widget.leading!),
                  const SizedBox(width: Gap.xs),
                ],
                Flexible(
                  child: Text(
                    widget.title,
                    style: Type.compact.copyWith(color: ds.textTertiary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );

    return Semantics(liveRegion: true, label: widget.title, child: child);
  }
}
