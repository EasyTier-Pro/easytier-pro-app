import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_motion.dart';

class AppSmoothScrollView extends StatefulWidget {
  const AppSmoothScrollView({
    super.key,
    this.scrollViewKey,
    this.controller,
    this.primary,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.padding,
    this.physics = appSmoothScrollPhysics,
    this.dragStartBehavior = DragStartBehavior.start,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.restorationId,
    this.clipBehavior = Clip.hardEdge,
    this.child,
  });

  final Key? scrollViewKey;
  final ScrollController? controller;
  final bool? primary;
  final Axis scrollDirection;
  final bool reverse;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics physics;
  final DragStartBehavior dragStartBehavior;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;
  final String? restorationId;
  final Clip clipBehavior;
  final Widget? child;

  @override
  State<AppSmoothScrollView> createState() => _AppSmoothScrollViewState();
}

class _AppSmoothScrollViewState extends State<AppSmoothScrollView> {
  ScrollController? _ownedController;
  _AppSmoothScrollController? _scrollController;

  ScrollController get _clientController =>
      widget.controller ?? (_ownedController ??= ScrollController());

  _AppSmoothScrollController get _effectiveScrollController =>
      _scrollController ??= _AppSmoothScrollController(
        clientController: _clientController,
      );

  @override
  void didUpdateWidget(covariant AppSmoothScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }

    _scrollController?.dispose();
    _scrollController = null;
    if (oldWidget.controller == null) {
      _ownedController?.dispose();
      _ownedController = null;
    }
  }

  @override
  void dispose() {
    _scrollController?.dispose();
    if (widget.controller == null) {
      _ownedController?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scrollController = _effectiveScrollController;

    return NotificationListener<OverscrollIndicatorNotification>(
      onNotification: (notification) {
        notification.disallowIndicator();
        return false;
      },
      child: SingleChildScrollView(
        key: widget.scrollViewKey,
        controller: scrollController,
        primary: widget.primary,
        scrollDirection: widget.scrollDirection,
        reverse: widget.reverse,
        padding: widget.padding,
        physics: widget.physics,
        dragStartBehavior: widget.dragStartBehavior,
        keyboardDismissBehavior: widget.keyboardDismissBehavior,
        restorationId: widget.restorationId,
        clipBehavior: widget.clipBehavior,
        child: widget.child,
      ),
    );
  }
}

class _AppSmoothScrollController extends ScrollController {
  _AppSmoothScrollController({required this.clientController})
    : super(
        initialScrollOffset: clientController.initialScrollOffset,
        keepScrollOffset: clientController.keepScrollOffset,
      );

  final ScrollController clientController;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _AppSmoothScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      initialPixels: initialScrollOffset,
    );
  }

  @override
  void attach(ScrollPosition position) {
    if (!clientController.positions.contains(position)) {
      clientController.attach(position);
    }
    super.attach(position);
  }

  @override
  void detach(ScrollPosition position) {
    if (clientController.positions.contains(position)) {
      clientController.detach(position);
    }
    super.detach(position);
  }
}

class _AppSmoothScrollPosition extends ScrollPositionWithSingleContext {
  _AppSmoothScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required double super.initialPixels,
  });

  static const double _edgeTolerance = 0.5;
  static const double _precisionScrollThreshold = 16;
  static const double _precisionScrollScale = 2.5;
  double? _targetPixels;
  int _lastWheelDirection = 0;

  @override
  void pointerScroll(double delta) {
    if (delta == 0) {
      return;
    }

    if (delta.abs() < _precisionScrollThreshold) {
      _targetPixels = null;
      _lastWheelDirection = 0;
      super.pointerScroll(delta * _precisionScrollScale);
      return;
    }

    if (!_canMove(delta)) {
      _targetPixels = _clampToExtents(pixels);
      _lastWheelDirection = delta.sign.toInt();
      return;
    }

    final direction = delta.sign.toInt();
    final baseOffset = direction == _lastWheelDirection
        ? _targetPixels ?? pixels
        : pixels;
    final target = _clampToExtents(baseOffset + delta);
    if ((target - pixels).abs() < _edgeTolerance) {
      _targetPixels = target;
      _lastWheelDirection = direction;
      return;
    }

    _targetPixels = target;
    _lastWheelDirection = direction;
    unawaited(
      animateTo(
        target,
        duration: appSmoothScrollDuration,
        curve: appMotionCurve,
      ),
    );
  }

  bool _canMove(double delta) {
    if (maxScrollExtent <= minScrollExtent) {
      return false;
    }
    if (delta < 0 && pixels <= minScrollExtent + _edgeTolerance) {
      return false;
    }
    if (delta > 0 && pixels >= maxScrollExtent - _edgeTolerance) {
      return false;
    }
    return true;
  }

  double _clampToExtents(double offset) {
    return offset.clamp(minScrollExtent, maxScrollExtent).toDouble();
  }
}
