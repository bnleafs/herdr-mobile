import 'package:flutter/material.dart';

import 'motion.dart';
import 'tokens.dart';

/// The MegaWatt brand mark: the app icon rendered on its rounded tile.
///
/// On first build it animates in (short fade-in); reduced motion, or
/// [animate] false, shows the finished mark at once.
class BrandMark extends StatefulWidget {
  const BrandMark({super.key, this.size = 64, this.animate = true});

  final double size;
  final bool animate;

  @override
  State<BrandMark> createState() => _BrandMarkState();
}

class _BrandMarkState extends State<BrandMark> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: Motion.brand);
  late final CurvedAnimation _opacity = CurvedAnimation(parent: _controller, curve: Motion.easeOut);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.animate || Motion.reduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The tile has the empty-state tile's shape, scaled (Radii.md on 52).
    final radius = Radii.md * widget.size / 52;
    Widget mark = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset(
        'assets/icon/icon.png',
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        semanticLabel: 'MegaWatt',
      ),
    );

    if (widget.animate) {
      mark = FadeTransition(opacity: _opacity, child: mark);
    }

    return mark;
  }
}
