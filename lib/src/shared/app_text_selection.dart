import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class AppTextSelectionController {
  AppTextSelectionController();

  final GlobalKey<SelectionAreaState> selectionAreaKey =
      GlobalKey<SelectionAreaState>();
  final ValueNotifier<bool> hasSelection = ValueNotifier<bool>(false);
  final Set<GlobalKey<SelectionAreaState>> _localSelectionAreaKeys =
      <GlobalKey<SelectionAreaState>>{};

  void handleSelectionChanged(SelectedContent? content) {
    hasSelection.value = content?.plainText.isNotEmpty == true;
  }

  void registerLocalSelectionArea(GlobalKey<SelectionAreaState> key) {
    _localSelectionAreaKeys.add(key);
  }

  void unregisterLocalSelectionArea(GlobalKey<SelectionAreaState> key) {
    _localSelectionAreaKeys.remove(key);
  }

  void clearSelection() {
    final keys = <GlobalKey<SelectionAreaState>>[
      selectionAreaKey,
      ..._localSelectionAreaKeys,
    ];
    for (final key in keys) {
      final state = key.currentState;
      if (state == null || !state.mounted) {
        continue;
      }
      try {
        state.selectableRegion.clearSelection();
      } on ConcurrentModificationError {
        scheduleMicrotask(clearSelection);
        return;
      }
    }
    hasSelection.value = false;
  }

  void reset() {
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
