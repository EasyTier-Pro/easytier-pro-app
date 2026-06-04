import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_text_selection.dart';

const Object _selectableTextHitBoundaryMarker = Object();

class SelectableTextHitBoundary extends StatefulWidget {
  const SelectableTextHitBoundary({super.key, required this.child});

  final Widget child;

  @override
  State<SelectableTextHitBoundary> createState() =>
      _SelectableTextHitBoundaryState();
}

class _SelectableTextHitBoundaryState extends State<SelectableTextHitBoundary> {
  final GlobalKey<SelectionAreaState> _selectionAreaKey =
      GlobalKey<SelectionAreaState>();

  @override
  void dispose() {
    appTextSelectionController.detach(_selectionAreaKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: _selectableTextHitBoundaryMarker,
      child: SelectionArea(
        key: _selectionAreaKey,
        onSelectionChanged: (content) {
          appTextSelectionController.handleSelectionChanged(
            _selectionAreaKey,
            content,
          );
        },
        child: widget.child,
      ),
    );
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
