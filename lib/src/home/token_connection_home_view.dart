import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import '../auth/console_auth_service.dart';
import '../core/core_lifecycle_service.dart';
import 'home_shell.dart';

class TokenConnectionHomeView extends StatefulWidget {
  const TokenConnectionHomeView({
    super.key,
    required this.profile,
    required this.coreLifecycleService,
    required this.onDisconnect,
    required this.onChangeToken,
    required this.onAccountLogin,
  });

  final TokenConnectionProfile profile;
  final CoreLifecycleService coreLifecycleService;
  final Future<void> Function() onDisconnect;
  final Future<void> Function() onChangeToken;
  final Future<void> Function() onAccountLogin;

  @override
  State<TokenConnectionHomeView> createState() =>
      _TokenConnectionHomeViewState();
}

class _TokenConnectionHomeViewState extends State<TokenConnectionHomeView> {
  static const double _mobileSwipeDistanceThreshold = 72;
  static const double _mobileSwipeHorizontalDominance = 1.25;

  _TokenHomeView _activeView = _TokenHomeView.overview;
  Timer? _trafficTimer;
  bool _trafficInFlight = false;
  Map<String, CoreNetworkTrafficTotals> _previousTotals =
      const <String, CoreNetworkTrafficTotals>{};
  Map<String, _TokenTrafficSnapshot> _traffic =
      const <String, _TokenTrafficSnapshot>{};
  String? _trafficError;

  @override
  void initState() {
    super.initState();
    widget.coreLifecycleService.status.addListener(_onCoreStatusChanged);
    _refreshTrafficPolling();
  }

  @override
  void didUpdateWidget(TokenConnectionHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coreLifecycleService != widget.coreLifecycleService) {
      oldWidget.coreLifecycleService.status.removeListener(
        _onCoreStatusChanged,
      );
      widget.coreLifecycleService.status.addListener(_onCoreStatusChanged);
      _refreshTrafficPolling();
    }
  }

  @override
  void dispose() {
    _trafficTimer?.cancel();
    widget.coreLifecycleService.status.removeListener(_onCoreStatusChanged);
    super.dispose();
  }

  void _onCoreStatusChanged() {
    if (mounted) {
      setState(() {});
    }
    _refreshTrafficPolling();
  }

  void _refreshTrafficPolling() {
    final running = widget.coreLifecycleService.status.value.isRunning;
    if (!running) {
      _trafficTimer?.cancel();
      _trafficTimer = null;
      return;
    }
    if (_trafficTimer != null) {
      return;
    }
    _trafficTimer = Timer.periodic(
      widget.coreLifecycleService.networkTrafficPollInterval,
      (_) => unawaited(_pollTraffic()),
    );
    unawaited(_pollTraffic());
  }

  Future<void> _pollTraffic() async {
    if (_trafficInFlight || !mounted) {
      return;
    }
    _trafficInFlight = true;
    try {
      final totals = await widget.coreLifecycleService
          .readNetworkTrafficTotals();
      if (!mounted) {
        return;
      }
      final next = <String, _TokenTrafficSnapshot>{};
      for (final entry in totals.entries) {
        next[entry.key] = _TokenTrafficSnapshot.fromTotals(
          entry.value,
          previous: _previousTotals[entry.key],
        );
      }
      setState(() {
        _traffic = next;
        _previousTotals = totals;
        _trafficError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _trafficError = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      _trafficInFlight = false;
    }
  }

  Future<void> _copyDiagnostics() async {
    final status = widget.coreLifecycleService.status.value;
    final lines = <String>[
      'mode=token',
      'name=${widget.profile.effectiveDisplayName}',
      'phase=${status.phase.name}',
      'message=${status.message}',
      'machine_id=${status.machineId ?? ''}',
      'details=${status.details ?? ''}',
      'config_server=${widget.profile.configServer}',
      if (status.lastError?.isNotEmpty == true) 'error=${status.lastError}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) {
      return;
    }
    showRawFToast(
      context: context,
      variant: FToastVariant.primary,
      duration: const Duration(seconds: 2),
      builder: (context, entry) => const FToast(title: Text('诊断信息已复制')),
    );
  }

  void _showOverview() {
    if (_activeView == _TokenHomeView.overview) {
      return;
    }
    setState(() {
      _activeView = _TokenHomeView.overview;
    });
  }

  void _showSettings() {
    if (_activeView == _TokenHomeView.settings) {
      return;
    }
    setState(() {
      _activeView = _TokenHomeView.settings;
    });
  }

  void _handleMobilePageSwipe(Offset delta) {
    final horizontalDistance = delta.dx.abs();
    final verticalDistance = delta.dy.abs();
    if (horizontalDistance < _mobileSwipeDistanceThreshold ||
        horizontalDistance <
            verticalDistance * _mobileSwipeHorizontalDominance) {
      return;
    }

    final currentIndex = _tokenMobileViewOrder.indexOf(_activeView);
    if (currentIndex < 0) {
      return;
    }

    final nextIndex = delta.dx < 0 ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex < 0 || nextIndex >= _tokenMobileViewOrder.length) {
      return;
    }

    switch (_tokenMobileViewOrder[nextIndex]) {
      case _TokenHomeView.overview:
        _showOverview();
      case _TokenHomeView.settings:
        _showSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.coreLifecycleService.status.value;
    final contentKey = ValueKey<String>('token-home:${_activeView.name}');
    final mobileNavigationIndex = switch (_activeView) {
      _TokenHomeView.overview => 0,
      _TokenHomeView.settings => 1,
    };

    return HomeShell(
      desktopHeader: HomeShellDesktopHeader(
        contentKey: const ValueKey<String>('token-desktop-dashboard-header'),
        navigation: [
          FButton(
            variant: _activeView == _TokenHomeView.overview
                ? .secondary
                : .ghost,
            size: .sm,
            onPress: _showOverview,
            child: const Text('首页'),
          ),
          const SizedBox(width: 6),
          FButton(
            variant: _activeView == _TokenHomeView.settings
                ? .secondary
                : .ghost,
            size: .sm,
            onPress: _showSettings,
            child: const Text('设置'),
          ),
        ],
        metrics: [
          const HomeHeaderMetric(
            label: '模式',
            value: '令牌',
            icon: Icons.vpn_key_outlined,
          ),
          HomeCoreStatusLabel(
            statusListenable: widget.coreLifecycleService.status,
            label: '连接',
          ),
        ],
        trailing: _TokenPhasePill(status: status),
      ),
      mobileHeader: HomeShellMobileHeader(
        title: 'EasyTier Pro',
        subtitle: '设备令牌连接 · ${widget.profile.effectiveDisplayName}',
        suffixes: [
          HomeCoreStatusDot(
            statusListenable: widget.coreLifecycleService.status,
          ),
        ],
      ),
      mobileNavigation: HomeShellMobileNavigation(
        navigationKey: const ValueKey<String>('mobile-dashboard-navigation'),
        index: mobileNavigationIndex,
        items: [
          HomeShellMobileNavigationItem(
            id: 'overview',
            key: const ValueKey<String>('mobile-nav-overview'),
            icon: Icons.home_outlined,
            label: '首页',
            onSelect: _showOverview,
          ),
          HomeShellMobileNavigationItem(
            id: 'settings',
            key: const ValueKey<String>('mobile-nav-settings'),
            icon: Icons.settings_outlined,
            label: '设置',
            onSelect: _showSettings,
          ),
        ],
      ),
      contentKey: contentKey,
      contentMode: HomeShellContentMode.scrollConstrained,
      onMobileSwipe: _handleMobilePageSwipe,
      child: switch (_activeView) {
        _TokenHomeView.overview => _TokenOverview(
          profile: widget.profile,
          status: status,
          traffic: _traffic,
          trafficError: _trafficError,
          onReconnect: () => unawaited(widget.coreLifecycleService.repair()),
          onCopyDiagnostics: () => unawaited(_copyDiagnostics()),
        ),
        _TokenHomeView.settings => Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _TokenActionPanel(
              profile: widget.profile,
              onDisconnect: () => unawaited(widget.onDisconnect()),
              onChangeToken: () => unawaited(widget.onChangeToken()),
              onAccountLogin: () => unawaited(widget.onAccountLogin()),
            ),
          ),
        ),
      },
    );
  }
}

enum _TokenHomeView { overview, settings }

const List<_TokenHomeView> _tokenMobileViewOrder = <_TokenHomeView>[
  _TokenHomeView.overview,
  _TokenHomeView.settings,
];

class _TokenOverview extends StatelessWidget {
  const _TokenOverview({
    required this.profile,
    required this.status,
    required this.traffic,
    required this.trafficError,
    required this.onReconnect,
    required this.onCopyDiagnostics,
  });

  final TokenConnectionProfile profile;
  final CoreRunStatus status;
  final Map<String, _TokenTrafficSnapshot> traffic;
  final String? trafficError;
  final VoidCallback onReconnect;
  final VoidCallback onCopyDiagnostics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 860;
        final statusPanel = _TokenStatusPanel(
          profile: profile,
          status: status,
          onReconnect: onReconnect,
          onCopyDiagnostics: onCopyDiagnostics,
        );
        final trafficPanel = _TokenTrafficPanel(
          traffic: traffic,
          trafficError: trafficError,
          running: status.isRunning,
        );

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 6, child: statusPanel),
              const SizedBox(width: 12),
              Expanded(flex: 4, child: trafficPanel),
            ],
          );
        }

        return Column(
          children: [statusPanel, const SizedBox(height: 12), trafficPanel],
        );
      },
    );
  }
}

class _TokenActionPanel extends StatelessWidget {
  const _TokenActionPanel({
    required this.profile,
    required this.onDisconnect,
    required this.onChangeToken,
    required this.onAccountLogin,
  });

  final TokenConnectionProfile profile;
  final VoidCallback onDisconnect;
  final VoidCallback onChangeToken;
  final VoidCallback onAccountLogin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.settings_outlined, size: 18),
                const SizedBox(width: 8),
                Text(
                  '连接设置',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _TokenInfoRow(label: '主机名', value: profile.effectiveDisplayName),
            _TokenInfoRow(label: '控制服务器', value: profile.configServer),
            const SizedBox(height: 14),
            Container(height: 1, color: const Color(0xFFE5E7EB)),
            const SizedBox(height: 14),
            FButton(
              variant: .outline,
              onPress: onChangeToken,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.key_outlined, size: 16),
                  SizedBox(width: 6),
                  Text('更换令牌'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FButton(
              variant: .outline,
              onPress: onAccountLogin,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.login, size: 16),
                  SizedBox(width: 6),
                  Text('使用账号登录'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FButton(
              variant: .destructive,
              onPress: onDisconnect,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.power_settings_new, size: 16),
                  SizedBox(width: 6),
                  Text('断开连接'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenStatusPanel extends StatelessWidget {
  const _TokenStatusPanel({
    required this.profile,
    required this.status,
    required this.onReconnect,
    required this.onCopyDiagnostics,
  });

  final TokenConnectionProfile profile;
  final CoreRunStatus status;
  final VoidCallback onReconnect;
  final VoidCallback onCopyDiagnostics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = status.lastError?.trim();
    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _phaseIcon(status.phase),
                  color: _phaseColor(status.phase),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status.message,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _TokenInfoRow(label: '本机设备', value: status.machineId ?? '等待注册'),
            _TokenInfoRow(label: '连接引擎', value: status.details ?? '准备中'),
            _TokenInfoRow(label: '控制服务器', value: profile.configServer),
            if (error != null && error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FButton(
                  onPress: onReconnect,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh, size: 16),
                      SizedBox(width: 6),
                      Text('重新连接'),
                    ],
                  ),
                ),
                FButton(
                  variant: .outline,
                  onPress: onCopyDiagnostics,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.content_copy, size: 16),
                      SizedBox(width: 6),
                      Text('复制诊断'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenTrafficPanel extends StatelessWidget {
  const _TokenTrafficPanel({
    required this.traffic,
    required this.trafficError,
    required this.running,
  });

  final Map<String, _TokenTrafficSnapshot> traffic;
  final String? trafficError;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = traffic.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));

    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.monitor_heart_outlined, size: 18),
                const SizedBox(width: 8),
                Text(
                  '运行实例',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (!running)
              _TokenMutedText('连接建立后会显示本机运行实例。')
            else if (trafficError != null && trafficError!.isNotEmpty)
              _TokenMutedText(trafficError!)
            else if (entries.isEmpty)
              const Row(
                children: [
                  FCircularProgress(size: .xs),
                  SizedBox(width: 8),
                  Text('正在读取实例状态...'),
                ],
              )
            else
              Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _TokenTrafficTile(
                      runtimeName: entries[i].key,
                      snapshot: entries[i].value,
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _TokenTrafficTile extends StatelessWidget {
  const _TokenTrafficTile({required this.runtimeName, required this.snapshot});

  final String runtimeName;
  final _TokenTrafficSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              runtimeName,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _RateBadge(
            icon: Icons.south_west,
            value: _formatTrafficRate(snapshot.downloadBytesPerSecond),
          ),
          const SizedBox(width: 6),
          _RateBadge(
            icon: Icons.north_east,
            value: _formatTrafficRate(snapshot.uploadBytesPerSecond),
          ),
        ],
      ),
    );
  }
}

class _TokenInfoRow extends StatelessWidget {
  const _TokenInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TokenPhasePill extends StatelessWidget {
  const _TokenPhasePill({required this.status});

  final CoreRunStatus status;

  @override
  Widget build(BuildContext context) {
    final color = _phaseColor(status.phase);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _phaseLabel(status.phase),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _TokenMutedText extends StatelessWidget {
  const _TokenMutedText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
      ),
    );
  }
}

class _RateBadge extends StatelessWidget {
  const _RateBadge({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 76),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: const Color(0xFF475569)),
          const SizedBox(width: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: const Color(0xFF334155),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TokenTrafficSnapshot {
  const _TokenTrafficSnapshot({
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

  factory _TokenTrafficSnapshot.fromTotals(
    CoreNetworkTrafficTotals totals, {
    CoreNetworkTrafficTotals? previous,
  }) {
    final elapsed = previous == null
        ? null
        : totals.sampledAt.difference(previous.sampledAt).inMilliseconds / 1000;
    double? rate(int current, int? last) {
      if (last == null || elapsed == null || elapsed <= 0 || current < last) {
        return null;
      }
      return (current - last) / elapsed;
    }

    return _TokenTrafficSnapshot(
      downloadBytes: totals.downloadBytes,
      uploadBytes: totals.uploadBytes,
      sampledAt: totals.sampledAt,
      downloadBytesPerSecond: rate(
        totals.downloadBytes,
        previous?.downloadBytes,
      ),
      uploadBytesPerSecond: rate(totals.uploadBytes, previous?.uploadBytes),
    );
  }
}

String _phaseLabel(CoreRunPhase phase) {
  return switch (phase) {
    CoreRunPhase.running => '已连接',
    CoreRunPhase.checking || CoreRunPhase.repairing => '连接中',
    CoreRunPhase.needsVpnPermission => '待授权',
    CoreRunPhase.needsElevation => '待授权',
    CoreRunPhase.error => '异常',
    CoreRunPhase.stopped => '已断开',
    CoreRunPhase.signedOut => '未连接',
  };
}

IconData _phaseIcon(CoreRunPhase phase) {
  return switch (phase) {
    CoreRunPhase.running => Icons.check_circle_outline,
    CoreRunPhase.checking || CoreRunPhase.repairing => Icons.sync,
    CoreRunPhase.needsVpnPermission => Icons.verified_user_outlined,
    CoreRunPhase.needsElevation => Icons.admin_panel_settings_outlined,
    CoreRunPhase.error => Icons.error_outline,
    CoreRunPhase.stopped || CoreRunPhase.signedOut => Icons.power_settings_new,
  };
}

Color _phaseColor(CoreRunPhase phase) {
  return switch (phase) {
    CoreRunPhase.running => const Color(0xFF16A34A),
    CoreRunPhase.checking || CoreRunPhase.repairing => const Color(0xFF2563EB),
    CoreRunPhase.needsVpnPermission ||
    CoreRunPhase.needsElevation => const Color(0xFFD97706),
    CoreRunPhase.error => const Color(0xFFDC2626),
    CoreRunPhase.stopped || CoreRunPhase.signedOut => const Color(0xFF64748B),
  };
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
