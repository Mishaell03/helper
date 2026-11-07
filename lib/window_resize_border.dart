import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Real Win32 resizing through window_manager, without resize-shaped cursors.
/// DragToResizeArea cannot configure its MouseRegions' cursors, so use our own
/// transparent hit areas. No cursor image is simulated and no global OS cursor
/// settings are changed.
class WindowResizeBorder extends StatelessWidget {
  const WindowResizeBorder({
    super.key,
    required this.child,
    required this.onResize,
    this.onVerticalMaximize,
  });

  final Widget child;
  final Future<void> Function(ResizeEdge) onResize;
  final VoidCallback? onVerticalMaximize;
  static const _width = 8.0;

  Widget _edge(
    ResizeEdge edge, {
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
  }) => Positioned(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    width: width,
    height: height,
    child: MouseRegion(
      key: ValueKey(edge),
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onResize(edge),
        onDoubleTap: edge == ResizeEdge.top || edge == ResizeEdge.bottom
            ? onVerticalMaximize
            : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      _edge(ResizeEdge.topLeft, left: 0, top: 0, width: _width, height: _width),
      _edge(
        ResizeEdge.top,
        left: _width,
        right: _width,
        top: 0,
        height: _width,
      ),
      _edge(
        ResizeEdge.topRight,
        right: 0,
        top: 0,
        width: _width,
        height: _width,
      ),
      _edge(
        ResizeEdge.left,
        left: 0,
        top: _width,
        bottom: _width,
        width: _width,
      ),
      _edge(
        ResizeEdge.right,
        right: 0,
        top: _width,
        bottom: _width,
        width: _width,
      ),
      _edge(
        ResizeEdge.bottomLeft,
        left: 0,
        bottom: 0,
        width: _width,
        height: _width,
      ),
      _edge(
        ResizeEdge.bottom,
        left: _width,
        right: _width,
        bottom: 0,
        height: _width,
      ),
      _edge(
        ResizeEdge.bottomRight,
        right: 0,
        bottom: 0,
        width: _width,
        height: _width,
      ),
    ],
  );
}
