import 'package:easytier_pro_app/src/home/network_traffic_sparkline.dart';
import 'package:fl_chart/fl_chart.dart';
// Inspect rendered samples, including the first frame of a chart update.
// ignore: implementation_imports
import 'package:fl_chart/src/chart/line_chart/line_chart_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

void main() {
  testWidgets('appending traffic renders the real samples on every frame', (
    tester,
  ) async {
    final start = DateTime.utc(2026, 1, 1);
    final history = ValueNotifier<List<HomeTrafficHistoryPoint>>([
      for (var i = 0; i < 3; i++)
        HomeTrafficHistoryPoint(
          timestamp: start.add(Duration(seconds: i * 2)),
          downloadRate: i * 50,
          uploadRate: i * 25,
        ),
    ]);
    addTearDown(history.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FTheme(data: FThemes.neutral.light.desktop, child: child!),
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<List<HomeTrafficHistoryPoint>>(
              valueListenable: history,
              builder: (context, value, child) =>
                  HomeNetworkTrafficSparkline(history: value),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(LineChart));
    await tester.pumpAndSettle();

    history.value = [
      ...history.value,
      HomeTrafficHistoryPoint(
        timestamp: start.add(const Duration(seconds: 6)),
        downloadRate: 0,
        uploadRate: 0,
      ),
    ];
    await tester.pump();
    await tester.pump();

    for (final elapsed in [0, 1, 50, 250]) {
      await tester.pump(Duration(milliseconds: elapsed));
      final rendered = tester
          .widgetList<LineChartLeaf>(find.byType(LineChartLeaf))
          .where((chart) => chart.targetData.titlesData.show)
          .single;
      expect(rendered.data.lineBarsData.first.spots, const [
        FlSpot(54, 0),
        FlSpot(56, 50),
        FlSpot(58, 100),
        FlSpot(60, 0),
      ]);
      expect(rendered.data.lineBarsData[1].spots, const [
        FlSpot(54, 0),
        FlSpot(56, 25),
        FlSpot(58, 50),
        FlSpot(60, 0),
      ]);
      for (final chart in tester.widgetList<LineChartLeaf>(
        find.byType(LineChartLeaf),
      )) {
        for (final line in chart.data.lineBarsData) {
          expect(line.isCurved, isFalse);
          for (var i = 1; i < line.spots.length; i++) {
            expect(line.spots[i].x, greaterThan(line.spots[i - 1].x));
          }
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}
