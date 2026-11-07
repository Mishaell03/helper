import 'package:flutter/material.dart';

/// First cursor annotation in every hit test, above even Navigator overlays.
/// Translucent hit testing lets the actual controls still receive all events.
class OrdinaryCursor extends StatelessWidget {
  const OrdinaryCursor({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      const Positioned.fill(
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          opaque: false,
          hitTestBehavior: HitTestBehavior.translucent,
        ),
      ),
    ],
  );
}
