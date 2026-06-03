import 'dart:ui';

import 'package:flutter/material.dart';

const Duration appMotionShort = Duration(milliseconds: 160);
const Duration appMotionMedium = Duration(milliseconds: 240);
const Curve appMotionCurve = Curves.easeOutCubic;
const Curve appMotionReverseCurve = Curves.easeInCubic;
const ScrollPhysics appScrollPhysics = BouncingScrollPhysics(
  parent: RangeMaintainingScrollPhysics(),
);

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return appScrollPhysics;
  }

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  };
}

Widget appFadeSlideTransition(Widget child, Animation<double> animation) {
  final curved = CurvedAnimation(
    parent: animation,
    curve: appMotionCurve,
    reverseCurve: appMotionReverseCurve,
  );
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.018),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    ),
  );
}

Widget appSwitcherStackLayout(
  Widget? currentChild,
  List<Widget> previousChildren,
) {
  return Stack(
    alignment: Alignment.topCenter,
    children: [...previousChildren, ?currentChild],
  );
}
