import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

const Object _selectableTextHitBoundaryMarker = Object();

class SelectableTextHitBoundary extends StatelessWidget {
  const SelectableTextHitBoundary({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MetaData(metaData: _selectableTextHitBoundaryMarker, child: child);
  }
}

bool tapStartedInsideSelectableText(BuildContext context, Offset position) {
  final view = View.maybeOf(context);
  if (view == null) {
    return false;
  }

  final result = HitTestResult();
  RendererBinding.instance.hitTestInView(result, position, view.viewId);
  return result.path.any((entry) {
    final target = entry.target;
    return target is RenderMetaData &&
        target.metaData == _selectableTextHitBoundaryMarker;
  });
}
