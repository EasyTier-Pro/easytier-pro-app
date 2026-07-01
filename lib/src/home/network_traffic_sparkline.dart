import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../shared/app_motion.dart';

class HomeTrafficHistoryPoint {
  const HomeTrafficHistoryPoint({
    required this.timestamp,
    required this.downloadRate,
    required this.uploadRate,
  });

  final DateTime timestamp;
  final double downloadRate;
  final double uploadRate;
}

class HomeNetworkTrafficSparkline extends StatefulWidget {
  const HomeNetworkTrafficSparkline({super.key, required this.history});

  final List<HomeTrafficHistoryPoint> history;

  @override
  State<HomeNetworkTrafficSparkline> createState() =>
      _HomeNetworkTrafficSparklineState();
}

class _HomeNetworkTrafficSparklineState
    extends State<HomeNetworkTrafficSparkline>
    with TickerProviderStateMixin {
  OverlayEntry? _detailOverlay;
  OverlayEntry? _fullscreenOverlay;
  Rect? _anchorRect;
  bool _overlayUpdateScheduled = false;
  late final AnimationController _overlayAnimationController;
  late final Animation<double> _overlayAnimation;
  late final AnimationController _fullscreenAnimationController;
  late final Animation<double> _fullscreenAnimation;
  _HomeTrafficTimeWindow _fullscreenTimeWindow =
      _HomeTrafficTimeWindow.oneMinute;

  @override
  void initState() {
    super.initState();
    _overlayAnimationController = AnimationController(
      vsync: this,
      duration: appMotionShort,
      reverseDuration: appMotionShort,
    );
    _overlayAnimation = CurvedAnimation(
      parent: _overlayAnimationController,
      curve: appMotionCurve,
      reverseCurve: appMotionReverseCurve,
    );
    _fullscreenAnimationController = AnimationController(
      vsync: this,
      duration: appMotionShort,
      reverseDuration: appMotionShort,
    );
    _fullscreenAnimation = CurvedAnimation(
      parent: _fullscreenAnimationController,
      curve: appMotionCurve,
      reverseCurve: appMotionReverseCurve,
    );
  }

  @override
  void didUpdateWidget(covariant HomeNetworkTrafficSparkline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_detailOverlay != null || _fullscreenOverlay != null) {
      _scheduleDetailOverlayUpdate();
    }
  }

  @override
  void dispose() {
    _removeDetailsImmediately();
    _removeFullscreenImmediately();
    _overlayAnimationController.dispose();
    _fullscreenAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final downloadColor = const Color(0xFF16A34A);
    final uploadColor = const Color(0xFF2563EB);
    final chart = _trafficSparklineData(widget.history);

    return MouseRegion(
      onEnter: (_) => _showDetails(),
      onExit: (_) => _hideDetails(),
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _showFullscreen,
          child: SizedBox(
            width: 100,
            height: 40,
            child: LineChart(
              _trafficSparklineChartData(
                chart: chart,
                downloadColor: downloadColor,
                uploadColor: uploadColor,
              ),
              duration: Duration.zero,
            ),
          ),
        ),
      ),
    );
  }

  void _showDetails() {
    if (_detailOverlay != null) {
      _overlayAnimationController.forward();
      return;
    }
    _updateAnchorRect();
    _detailOverlay = OverlayEntry(
      builder: (context) => _HomeNetworkTrafficDetailOverlay(
        anchorRect: _anchorRect,
        history: widget.history,
        animation: _overlayAnimation,
      ),
    );
    Overlay.of(context).insert(_detailOverlay!);
    _overlayAnimationController.forward(from: 0);
  }

  void _hideDetails() {
    final overlay = _detailOverlay;
    if (overlay == null) {
      return;
    }

    _overlayAnimationController.reverse().whenComplete(() {
      if (_detailOverlay != overlay) {
        return;
      }

      overlay.remove();
      _detailOverlay = null;
    });
  }

  void _removeDetailsImmediately() {
    _detailOverlay?.remove();
    _detailOverlay = null;
  }

  void _showFullscreen() {
    _removeDetailsImmediately();
    final overlay = _fullscreenOverlay;
    if (overlay != null) {
      overlay.markNeedsBuild();
      _fullscreenAnimationController.forward();
      return;
    }

    _fullscreenOverlay = OverlayEntry(
      builder: (context) => _HomeNetworkTrafficFullscreenOverlay(
        history: widget.history,
        animation: _fullscreenAnimation,
        timeWindow: _fullscreenTimeWindow,
        onTimeWindowChanged: _setFullscreenTimeWindow,
        onClose: _hideFullscreen,
      ),
    );
    Overlay.of(context).insert(_fullscreenOverlay!);
    _fullscreenAnimationController.forward(from: 0);
  }

  void _hideFullscreen() {
    final overlay = _fullscreenOverlay;
    if (overlay == null) {
      return;
    }

    _fullscreenAnimationController.reverse().whenComplete(() {
      if (_fullscreenOverlay != overlay) {
        return;
      }

      overlay.remove();
      _fullscreenOverlay = null;
    });
  }

  void _removeFullscreenImmediately() {
    _fullscreenOverlay?.remove();
    _fullscreenOverlay = null;
    _fullscreenAnimationController.reset();
  }

  void _setFullscreenTimeWindow(_HomeTrafficTimeWindow timeWindow) {
    if (_fullscreenTimeWindow == timeWindow) {
      return;
    }

    _fullscreenTimeWindow = timeWindow;
    _fullscreenOverlay?.markNeedsBuild();
  }

  void _scheduleDetailOverlayUpdate() {
    if (_overlayUpdateScheduled) {
      return;
    }

    _overlayUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayUpdateScheduled = false;
      if (!mounted || (_detailOverlay == null && _fullscreenOverlay == null)) {
        return;
      }

      _updateAnchorRect();
      _detailOverlay?.markNeedsBuild();
      _fullscreenOverlay?.markNeedsBuild();
    });
  }

  void _updateAnchorRect() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) {
      return;
    }

    final topLeft = box.localToGlobal(Offset.zero);
    _anchorRect = topLeft & box.size;
  }
}

class _HomeNetworkTrafficFullscreenOverlay extends StatelessWidget {
  const _HomeNetworkTrafficFullscreenOverlay({
    required this.history,
    required this.animation,
    required this.timeWindow,
    required this.onTimeWindowChanged,
    required this.onClose,
  });

  final List<HomeTrafficHistoryPoint> history;
  final Animation<double> animation;
  final _HomeTrafficTimeWindow timeWindow;
  final ValueChanged<_HomeTrafficTimeWindow> onTimeWindowChanged;
  final VoidCallback onClose;

  static const double _screenPadding = 24;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final panelWidth = math.min(screenSize.width - (_screenPadding * 2), 960.0);
    final panelHeight = math.min(
      math.min(screenSize.height - (_screenPadding * 2), 720.0),
      panelWidth,
    );

    return Positioned.fill(
      child: Material(
        color: Colors.transparent,
        child: FadeTransition(
          key: const ValueKey<String>('traffic-fullscreen-animation'),
          opacity: animation,
          child: GestureDetector(
            key: const ValueKey<String>('traffic-fullscreen-overlay'),
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: Container(
              color: const Color(0xFF020617).withAlpha(170),
              padding: const EdgeInsets.all(_screenPadding),
              child: Center(
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.98, end: 1).animate(animation),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: SizedBox(
                      key: const ValueKey<String>('traffic-fullscreen-panel'),
                      width: panelWidth,
                      height: panelHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF020617).withAlpha(60),
                              blurRadius: 34,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final title = Text(
                                    '实时流量',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          color: const Color(0xFF0F172A),
                                        ),
                                  );
                                  final selector =
                                      _HomeTrafficTimeWindowSelector(
                                        selected: timeWindow,
                                        onChanged: onTimeWindowChanged,
                                      );
                                  final closeButton = FButton(
                                    key: const ValueKey<String>(
                                      'traffic-fullscreen-close',
                                    ),
                                    variant: .ghost,
                                    size: .sm,
                                    onPress: onClose,
                                    mainAxisSize: MainAxisSize.min,
                                    child: const Icon(Icons.close, size: 18),
                                  );

                                  if (constraints.maxWidth < 340) {
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(child: title),
                                            closeButton,
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        selector,
                                      ],
                                    );
                                  }

                                  return Row(
                                    children: [
                                      title,
                                      const Spacer(),
                                      selector,
                                      const SizedBox(width: 10),
                                      closeButton,
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 14),
                              Expanded(
                                child: _HomeNetworkTrafficDetailChart(
                                  history: history,
                                  showTitle: false,
                                  timeWindow: timeWindow,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _HomeTrafficTimeWindow {
  oneMinute('1min', Duration(minutes: 1)),
  fifteenMinutes('15min', Duration(minutes: 15)),
  sixtyMinutes('60min', Duration(minutes: 60));

  const _HomeTrafficTimeWindow(this.label, this.duration);

  final String label;
  final Duration duration;
}

class _HomeTrafficTimeWindowSelector extends StatelessWidget {
  const _HomeTrafficTimeWindowSelector({
    required this.selected,
    required this.onChanged,
  });

  final _HomeTrafficTimeWindow selected;
  final ValueChanged<_HomeTrafficTimeWindow> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final window in _HomeTrafficTimeWindow.values)
              _HomeTrafficTimeWindowButton(
                window: window,
                selected: window == selected,
                onTap: () => onChanged(window),
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeTrafficTimeWindowButton extends StatelessWidget {
  const _HomeTrafficTimeWindowButton({
    required this.window,
    required this.selected,
    required this.onTap,
  });

  final _HomeTrafficTimeWindow window;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey<String>('traffic-window-${window.label}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF0F172A) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            window.label,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xFF64748B),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeNetworkTrafficDetailOverlay extends StatelessWidget {
  const _HomeNetworkTrafficDetailOverlay({
    required this.anchorRect,
    required this.history,
    required this.animation,
  });

  final Rect? anchorRect;
  final List<HomeTrafficHistoryPoint> history;
  final Animation<double> animation;

  static const Size _panelSize = Size(320, 244);
  static const double _screenPadding = 12;

  @override
  Widget build(BuildContext context) {
    final anchor = anchorRect;
    if (anchor == null || history.isEmpty) {
      return const SizedBox.shrink();
    }

    final screenSize = MediaQuery.sizeOf(context);
    final preferredTop = anchor.bottom + 10;
    final top = math.min(
      preferredTop,
      math.max(
        _screenPadding,
        screenSize.height - _panelSize.height - _screenPadding,
      ),
    );
    final left = (anchor.center.dx - (_panelSize.width / 2)).clamp(
      _screenPadding,
      math.max(
        _screenPadding,
        screenSize.width - _panelSize.width - _screenPadding,
      ),
    );

    return Positioned(
      left: left.toDouble(),
      top: top.toDouble(),
      width: _panelSize.width,
      height: _panelSize.height,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: FadeTransition(
            opacity: animation,
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, -6 + (6 * animation.value)),
                  child: child,
                );
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0F172A).withAlpha(22),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: _HomeNetworkTrafficDetailChart(history: history),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeNetworkTrafficDetailChart extends StatelessWidget {
  const _HomeNetworkTrafficDetailChart({
    required this.history,
    this.showTitle = true,
    this.timeWindow = _HomeTrafficTimeWindow.oneMinute,
  });

  final List<HomeTrafficHistoryPoint> history;
  final bool showTitle;
  final _HomeTrafficTimeWindow timeWindow;

  @override
  Widget build(BuildContext context) {
    final downloadColor = const Color(0xFF16A34A);
    final uploadColor = const Color(0xFF2563EB);
    final chart = _trafficDetailChartData(history, timeWindow);
    final latest = chart.visibleHistory.last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle) ...[
          Text(
            '实时流量',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
        ],
        Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _HomeTrafficLegendValue(
              icon: Icons.arrow_downward,
              color: downloadColor,
              text: _formatTrafficRate(latest.downloadRate),
            ),
            _HomeTrafficLegendValue(
              icon: Icons.arrow_upward,
              color: uploadColor,
              text: _formatTrafficRate(latest.uploadRate),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: LineChart(
            _trafficSparklineChartData(
              chart: chart,
              downloadColor: downloadColor,
              uploadColor: uploadColor,
              detailed: true,
            ),
            duration: appMotionMedium,
            curve: appMotionCurve,
          ),
        ),
      ],
    );
  }
}

class _HomeTrafficLegendValue extends StatelessWidget {
  const _HomeTrafficLegendValue({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _TrafficSparklineData {
  const _TrafficSparklineData({
    required this.visibleHistory,
    required this.downloadSpots,
    required this.uploadSpots,
    required this.minX,
    required this.maxX,
    required this.yMax,
    required this.hasTraffic,
    required this.xAxisStartTime,
    required this.xAxisEndTime,
  });

  final List<HomeTrafficHistoryPoint> visibleHistory;
  final List<FlSpot> downloadSpots;
  final List<FlSpot> uploadSpots;
  final double minX;
  final double maxX;
  final double yMax;
  final bool hasTraffic;
  final DateTime xAxisStartTime;
  final DateTime xAxisEndTime;
}

_TrafficSparklineData _trafficSparklineData(
  List<HomeTrafficHistoryPoint> history,
) {
  const maxHistoryPoints = 30;
  final visibleHistory = history.length > maxHistoryPoints
      ? history.sublist(history.length - maxHistoryPoints)
      : history;

  final maxRate = visibleHistory
      .map((h) => math.max(h.downloadRate, h.uploadRate))
      .fold(0.0, math.max);
  final hasTraffic = maxRate > 0;
  final yMax = _trafficSparklineYMax(maxRate);

  const minX = 0.0;
  final maxX = (maxHistoryPoints - 1).toDouble();
  final firstX = maxX - (visibleHistory.length - 1);

  final downloadSpots = <FlSpot>[
    for (var i = 0; i < visibleHistory.length; i++)
      FlSpot(firstX + i, visibleHistory[i].downloadRate),
  ];
  final uploadSpots = <FlSpot>[
    for (var i = 0; i < visibleHistory.length; i++)
      FlSpot(firstX + i, visibleHistory[i].uploadRate),
  ];

  return _TrafficSparklineData(
    visibleHistory: visibleHistory,
    downloadSpots: downloadSpots,
    uploadSpots: uploadSpots,
    minX: minX,
    maxX: maxX,
    yMax: yMax,
    hasTraffic: hasTraffic,
    xAxisStartTime: visibleHistory.first.timestamp,
    xAxisEndTime: visibleHistory.last.timestamp,
  );
}

_TrafficSparklineData _trafficDetailChartData(
  List<HomeTrafficHistoryPoint> history,
  _HomeTrafficTimeWindow timeWindow,
) {
  final latestTimestamp = history.last.timestamp;
  final windowStart = latestTimestamp.subtract(timeWindow.duration);
  final visibleHistory = history
      .where((point) => !point.timestamp.isBefore(windowStart))
      .toList(growable: false);
  final chartHistory = visibleHistory.isEmpty
      ? <HomeTrafficHistoryPoint>[history.last]
      : visibleHistory;

  final maxRate = chartHistory
      .map((h) => math.max(h.downloadRate, h.uploadRate))
      .fold(0.0, math.max);
  final hasTraffic = maxRate > 0;
  final yMax = _trafficSparklineYMax(maxRate);

  const minX = 0.0;
  final maxX = timeWindow.duration.inSeconds.toDouble();

  double xFor(HomeTrafficHistoryPoint point) {
    final seconds =
        point.timestamp.difference(windowStart).inMilliseconds / 1000;
    return seconds.clamp(minX, maxX).toDouble();
  }

  final downloadSpots = <FlSpot>[
    for (final point in chartHistory) FlSpot(xFor(point), point.downloadRate),
  ];
  final uploadSpots = <FlSpot>[
    for (final point in chartHistory) FlSpot(xFor(point), point.uploadRate),
  ];

  return _TrafficSparklineData(
    visibleHistory: chartHistory,
    downloadSpots: downloadSpots,
    uploadSpots: uploadSpots,
    minX: minX,
    maxX: maxX,
    yMax: yMax,
    hasTraffic: hasTraffic,
    xAxisStartTime: windowStart,
    xAxisEndTime: latestTimestamp,
  );
}

LineChartData _trafficSparklineChartData({
  required _TrafficSparklineData chart,
  required Color downloadColor,
  required Color uploadColor,
  bool detailed = false,
}) {
  return LineChartData(
    minX: chart.minX,
    maxX: chart.maxX,
    minY: 0,
    maxY: chart.yMax,
    gridData: FlGridData(
      show: detailed,
      drawVerticalLine: false,
      horizontalInterval: chart.yMax / 2,
      getDrawingHorizontalLine: (_) =>
          FlLine(color: const Color(0xFFE2E8F0).withAlpha(180), strokeWidth: 1),
    ),
    titlesData: detailed
        ? FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitleAlignment: SideTitleAlignment.inside,
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                interval: chart.yMax,
                minIncluded: false,
                getTitlesWidget: (value, meta) => _trafficYAxisTitle(
                  value: value,
                  meta: meta,
                  maxY: chart.yMax,
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitleAlignment: SideTitleAlignment.outside,
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: chart.maxX,
                getTitlesWidget: (value, meta) => _trafficXAxisTitle(
                  value: value,
                  meta: meta,
                  minX: chart.minX,
                  maxX: chart.maxX,
                  startTime: chart.xAxisStartTime,
                  endTime: chart.xAxisEndTime,
                ),
              ),
            ),
          )
        : const FlTitlesData(show: false),
    borderData: detailed
        ? FlBorderData(
            show: true,
            border: const Border(
              left: BorderSide(color: Color(0xFFCBD5E1)),
              bottom: BorderSide(color: Color(0xFFCBD5E1)),
            ),
          )
        : FlBorderData(show: false),
    lineTouchData: const LineTouchData(enabled: false),
    lineBarsData: [
      _buildTrafficLine(chart.downloadSpots, downloadColor, detailed: detailed),
      _buildTrafficLine(chart.uploadSpots, uploadColor, detailed: detailed),
      if (!chart.hasTraffic)
        LineChartBarData(
          spots: [FlSpot(chart.minX, 0), FlSpot(chart.maxX, 0)],
          barWidth: 1,
          dotData: const FlDotData(show: false),
          color: const Color(0xFFCBD5E1),
          belowBarData: BarAreaData(show: false),
        ),
    ],
  );
}

Widget _trafficYAxisTitle({
  required double value,
  required TitleMeta meta,
  required double maxY,
}) {
  final isMax = (value - maxY).abs() < 0.001;
  if (!isMax) {
    return const SizedBox.shrink();
  }

  return SideTitleWidget(
    meta: meta,
    space: 6,
    child: Transform.translate(
      offset: const Offset(8, 0),
      child: Text(
        _formatTrafficRate(maxY),
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
        style: const TextStyle(
          color: Color(0xFF64748B),
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

Widget _trafficXAxisTitle({
  required double value,
  required TitleMeta meta,
  required double minX,
  required double maxX,
  required DateTime startTime,
  required DateTime endTime,
}) {
  final isMin = (value - minX).abs() < 0.001;
  final isMax = (value - maxX).abs() < 0.001;
  if (!isMin && !isMax) {
    return const SizedBox.shrink();
  }

  return SideTitleWidget(
    meta: meta,
    space: 6,
    fitInside: SideTitleFitInsideData.fromTitleMeta(meta, distanceFromEdge: 4),
    child: Text(
      _formatTrafficTime(isMin ? startTime : endTime),
      maxLines: 1,
      overflow: TextOverflow.visible,
      softWrap: false,
      style: const TextStyle(
        color: Color(0xFF64748B),
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

LineChartBarData _buildTrafficLine(
  List<FlSpot> spots,
  Color color, {
  bool detailed = false,
}) {
  return LineChartBarData(
    spots: spots,
    isCurved: spots.length >= 4,
    curveSmoothness: 0.3,
    barWidth: detailed ? 2.2 : 1.8,
    isStrokeCapRound: true,
    dotData: const FlDotData(show: false),
    color: color,
    belowBarData: BarAreaData(
      show: spots.length > 1,
      color: color.withAlpha(detailed ? 28 : 35),
    ),
  );
}

double _trafficSparklineYMax(double maxRate) {
  const fixedScales = <double>[
    1024,
    10 * 1024,
    100 * 1024,
    1024 * 1024,
    10 * 1024 * 1024,
    100 * 1024 * 1024,
    1024 * 1024 * 1024,
    10 * 1024 * 1024 * 1024,
    100 * 1024 * 1024 * 1024,
    1024 * 1024 * 1024 * 1024,
  ];

  for (final scale in fixedScales) {
    if (maxRate <= scale) {
      return scale;
    }
  }

  return fixedScales.last;
}

String _formatTrafficRate(double? bytesPerSecond) {
  if (bytesPerSecond == null) {
    return '计算中';
  }
  return '${_formatBytes(bytesPerSecond)}/s';
}

String _formatBytes(num bytes) {
  const units = <String>['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value = value / 1024;
    unitIndex++;
  }
  if (unitIndex == 0) {
    return '${value.round()} ${units[unitIndex]}';
  }
  final decimals = value >= 10 ? 1 : 2;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

String _formatTrafficTime(DateTime time) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(time.hour)}:${twoDigits(time.minute)}:${twoDigits(time.second)}';
}
