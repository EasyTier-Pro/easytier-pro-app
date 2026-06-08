import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_motion.dart';

enum AppScrollDeltaSource { pointerSignal, userDrag }

typedef AppScrollDeltaCoordinator =
    double Function(
      double delta,
      ScrollMetrics metrics, {
      AppScrollDeltaSource source,
    });

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
    this.scrollDeltaCoordinator,
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
  final AppScrollDeltaCoordinator? scrollDeltaCoordinator;
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
    scrollController.scrollDeltaCoordinator = widget.scrollDeltaCoordinator;

    return NotificationListener<OverscrollIndicatorNotification>(
      onNotification: (notification) {
        notification.disallowIndicator();
        return false;
      },
      child: Listener(
        onPointerSignal: (event) =>
            _handlePointerSignal(event, scrollController),
        onPointerMove: (event) => _handlePointerMove(event, scrollController),
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
      ),
    );
  }

  void _handlePointerSignal(
    PointerSignalEvent event,
    _AppSmoothScrollController scrollController,
  ) {
    final coordinator = widget.scrollDeltaCoordinator;
    if (coordinator == null ||
        event is! PointerScrollEvent ||
        !scrollController.hasClients ||
        event.scrollDelta.dy == 0) {
      return;
    }

    final position = scrollController.position;
    final atLeadingEdge = position.pixels <= position.minScrollExtent + 0.5;
    final cannotScroll =
        position.maxScrollExtent <= position.minScrollExtent + 0.5;
    if (!atLeadingEdge || (event.scrollDelta.dy > 0 && !cannotScroll)) {
      return;
    }

    final remainingDelta = coordinator(
      event.scrollDelta.dy,
      position,
      source: AppScrollDeltaSource.pointerSignal,
    );
    if (remainingDelta == event.scrollDelta.dy) {
      return;
    }

    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (remainingDelta != 0 && scrollController.hasClients) {
        scrollController.position.pointerScroll(remainingDelta);
      }
    });
  }

  void _handlePointerMove(
    PointerMoveEvent event,
    _AppSmoothScrollController scrollController,
  ) {
    final coordinator = widget.scrollDeltaCoordinator;
    if (coordinator == null ||
        !scrollController.hasClients ||
        widget.scrollDirection != Axis.vertical ||
        event.buttons == 0) {
      return;
    }

    final position = scrollController.position;
    if (position.maxScrollExtent > position.minScrollExtent + 0.5 ||
        position.pixels > position.minScrollExtent + 0.5 ||
        event.delta.dy == 0) {
      return;
    }

    coordinator(
      -event.delta.dy,
      position,
      source: AppScrollDeltaSource.userDrag,
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
  AppScrollDeltaCoordinator? scrollDeltaCoordinator;

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
      scrollDeltaCoordinatorProvider: () => scrollDeltaCoordinator,
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
    required this.scrollDeltaCoordinatorProvider,
  });

  final AppScrollDeltaCoordinator? Function() scrollDeltaCoordinatorProvider;
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
      final remainingDelta = _coordinateScrollDelta(
        delta * _precisionScrollScale,
        source: AppScrollDeltaSource.pointerSignal,
      );
      _targetPixels = null;
      _lastWheelDirection = 0;
      if (remainingDelta != 0) {
        super.pointerScroll(remainingDelta);
      }
      return;
    }

    final remainingDelta = _coordinateScrollDelta(
      delta,
      source: AppScrollDeltaSource.pointerSignal,
    );
    if (remainingDelta == 0) {
      _targetPixels = _clampToExtents(pixels);
      _lastWheelDirection = 0;
      return;
    }

    if (!_canMove(remainingDelta)) {
      _targetPixels = _clampToExtents(pixels);
      _lastWheelDirection = remainingDelta.sign.toInt();
      return;
    }

    final direction = remainingDelta.sign.toInt();
    final baseOffset = direction == _lastWheelDirection
        ? _targetPixels ?? pixels
        : pixels;
    final rawTarget = baseOffset + remainingDelta;
    final target = _clampToExtents(rawTarget);
    if (direction < 0 && rawTarget < minScrollExtent) {
      // Let coordinated headers react as soon as the smooth-scroll target
      // reaches the leading edge, even while the visible pixels are animating.
      _coordinateScrollDelta(
        rawTarget - minScrollExtent,
        metrics: copyWith(pixels: minScrollExtent),
        source: AppScrollDeltaSource.pointerSignal,
      );
    }

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

  @override
  void applyUserOffset(double delta) {
    final scrollDelta = -delta;
    final remainingScrollDelta = _coordinateScrollDelta(
      scrollDelta,
      source: AppScrollDeltaSource.userDrag,
    );
    if (remainingScrollDelta == 0) {
      return;
    }
    super.applyUserOffset(-remainingScrollDelta);
  }

  double _coordinateScrollDelta(
    double delta, {
    ScrollMetrics? metrics,
    required AppScrollDeltaSource source,
  }) {
    final coordinator = scrollDeltaCoordinatorProvider();
    if (coordinator == null || delta == 0) {
      return delta;
    }
    return coordinator(delta, metrics ?? this, source: source);
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
