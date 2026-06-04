import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class AppTextSelectionController {
  AppTextSelectionController();

  final ValueNotifier<bool> hasSelection = ValueNotifier<bool>(false);
  GlobalKey<SelectionAreaState>? _activeSelectionAreaKey;

  void handleSelectionChanged(
    GlobalKey<SelectionAreaState> selectionAreaKey,
    SelectedContent? content,
  ) {
    final hasContent = content?.plainText.isNotEmpty == true;
    if (hasContent) {
      _activeSelectionAreaKey = selectionAreaKey;
      hasSelection.value = true;
      return;
    }
    if (_activeSelectionAreaKey == selectionAreaKey) {
      _activeSelectionAreaKey = null;
      hasSelection.value = false;
    }
  }

  void clearSelection() {
    final selectionAreaKey = _activeSelectionAreaKey;
    _activeSelectionAreaKey = null;
    if (selectionAreaKey == null) {
      hasSelection.value = false;
      return;
    }
    final state = selectionAreaKey.currentState;
    if (state == null || !state.mounted) {
      hasSelection.value = false;
      return;
    }
    state.selectableRegion.clearSelection();
    hasSelection.value = false;
  }

  void detach(GlobalKey<SelectionAreaState> selectionAreaKey) {
    if (_activeSelectionAreaKey == selectionAreaKey) {
      _activeSelectionAreaKey = null;
      hasSelection.value = false;
    }
  }

  void reset() {
    _activeSelectionAreaKey = null;
    hasSelection.value = false;
  }
}

final AppTextSelectionController appTextSelectionController =
    AppTextSelectionController();

class AppTextSelectionTapCleaner extends StatefulWidget {
  const AppTextSelectionTapCleaner({super.key, required this.child});

  final Widget child;

  @override
  State<AppTextSelectionTapCleaner> createState() =>
      _AppTextSelectionTapCleanerState();
}

class _AppTextSelectionTapCleanerState
    extends State<AppTextSelectionTapCleaner> {
  static const double _tapSlop = 6;

  Offset? _tapStart;
  bool _trackingTap = false;
  bool _tapMoved = false;
  bool _clearSelectionScheduled = false;

  @override
  void initState() {
    super.initState();
    appTextSelectionController.reset();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: (_) => _resetTapTracking(),
      child: widget.child,
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryMouseButton) {
      _resetTapTracking();
      return;
    }
    _tapStart = event.position;
    _trackingTap = true;
    _tapMoved = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final start = _tapStart;
    if (!_trackingTap || start == null) {
      return;
    }
    if ((event.position - start).distance > _tapSlop) {
      _tapMoved = true;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    final shouldClear =
        _trackingTap &&
        !_tapMoved &&
        appTextSelectionController.hasSelection.value;
    _resetTapTracking();
    if (!shouldClear) {
      return;
    }
    _scheduleClearSelection();
  }

  void _resetTapTracking() {
    _tapStart = null;
    _trackingTap = false;
    _tapMoved = false;
  }

  void _scheduleClearSelection() {
    if (_clearSelectionScheduled) {
      return;
    }
    _clearSelectionScheduled = true;
    unawaited(
      WidgetsBinding.instance.endOfFrame.then((_) {
        Timer.run(() {
          _clearSelectionScheduled = false;
          if (!mounted || !appTextSelectionController.hasSelection.value) {
            return;
          }
          appTextSelectionController.clearSelection();
        });
      }),
    );
  }
}
