import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Flutter's consecutive-tap recognizer delivers the first tap immediately,
/// without a competing double-tap recognizer holding the gesture arena.
class BlockTapRegion extends StatefulWidget {
  const BlockTapRegion({
    super.key,
    required this.enabled,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    required this.child,
  });

  final bool enabled;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final Widget child;

  @override
  State<BlockTapRegion> createState() => _BlockTapRegionState();
}

class _BlockTapRegionState extends State<BlockTapRegion> {
  int _sequence = 0;

  @override
  void didUpdateWidget(BlockTapRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled ||
        (oldWidget.selected && !widget.selected)) {
      ++_sequence;
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    onTap: widget.enabled ? widget.onSelect : null,
    child: RawGestureDetector(
      key: ValueKey(_sequence),
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      gestures: {
        if (widget.enabled)
          TapAndPanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapAndPanGestureRecognizer>(
                () => TapAndPanGestureRecognizer(),
                (recognizer) => recognizer
                  ..maxConsecutiveTap = 2
                  ..eagerVictoryOnDrag = false
                  ..onTapUp = (details) {
                    widget.onSelect();
                    if (details.consecutiveTapCount == 2) widget.onOpen();
                  },
              ),
      },
      child: widget.child,
    ),
  );
}
