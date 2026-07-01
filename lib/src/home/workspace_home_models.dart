part of 'workspace_home_view.dart';

enum _DashboardView { overview, network, devices, settings }

HomeDashboardView _homeDashboardViewFor(_DashboardView view) {
  return switch (view) {
    _DashboardView.overview => HomeDashboardView.overview,
    _DashboardView.network => HomeDashboardView.network,
    _DashboardView.devices => HomeDashboardView.devices,
    _DashboardView.settings => HomeDashboardView.settings,
  };
}

List<HomeDashboardNetworkOption> _homeDashboardNetworkOptions(
  Iterable<ConsoleNetwork> networks,
) {
  return [
    for (final network in networks)
      HomeDashboardNetworkOption(id: network.id, name: network.name),
  ];
}

enum _NetworkDetailSection { nodes, subnets, local }

const List<_DashboardView> _mobileDashboardViewOrder = <_DashboardView>[
  _DashboardView.overview,
  _DashboardView.network,
  _DashboardView.devices,
  _DashboardView.settings,
];

enum _JoinPhase { idle, joining, joined, leaving, error }

const double _mobileShellBreakpoint = homeShellMobileBreakpoint;

class _JoinNetworkState {
  const _JoinNetworkState({required this.phase, this.message, this.localIpv4});

  final _JoinPhase phase;
  final String? message;
  final String? localIpv4;

  static const idle = _JoinNetworkState(phase: _JoinPhase.idle);
  static const joining = _JoinNetworkState(phase: _JoinPhase.joining);
  static const leaving = _JoinNetworkState(phase: _JoinPhase.leaving);

  static _JoinNetworkState joinedWithIp(String? localIpv4, {String? message}) {
    final value = localIpv4?.trim();
    return _JoinNetworkState(
      phase: _JoinPhase.joined,
      message: message,
      localIpv4: value == null || value.isEmpty ? null : value,
    );
  }

  static _JoinNetworkState error(String message) {
    return _JoinNetworkState(phase: _JoinPhase.error, message: message);
  }
}

typedef _TrafficHistoryPoint = HomeTrafficHistoryPoint;

class _NetworkTrafficSnapshot {
  const _NetworkTrafficSnapshot({
    required this.downloadBytes,
    required this.uploadBytes,
    required this.sampledAt,
    this.downloadBytesPerSecond,
    this.uploadBytesPerSecond,
  });

  final int downloadBytes;
  final int uploadBytes;
  final DateTime sampledAt;
  final double? downloadBytesPerSecond;
  final double? uploadBytesPerSecond;

  static _NetworkTrafficSnapshot fromTotals(
    CoreNetworkTrafficTotals totals, {
    CoreNetworkTrafficTotals? previous,
  }) {
    double? downloadRate;
    double? uploadRate;
    final elapsedMilliseconds = previous == null
        ? 0
        : totals.sampledAt.difference(previous.sampledAt).inMilliseconds;
    if (previous != null && elapsedMilliseconds > 0) {
      final elapsedSeconds = elapsedMilliseconds / 1000;
      final downloadDelta = totals.downloadBytes - previous.downloadBytes;
      final uploadDelta = totals.uploadBytes - previous.uploadBytes;
      downloadRate = (downloadDelta < 0 ? 0 : downloadDelta) / elapsedSeconds;
      uploadRate = (uploadDelta < 0 ? 0 : uploadDelta) / elapsedSeconds;
    }

    return _NetworkTrafficSnapshot(
      downloadBytes: totals.downloadBytes,
      uploadBytes: totals.uploadBytes,
      sampledAt: totals.sampledAt,
      downloadBytesPerSecond: downloadRate,
      uploadBytesPerSecond: uploadRate,
    );
  }
}
