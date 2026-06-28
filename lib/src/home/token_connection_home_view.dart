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

  Future<void> _copyText(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    showRawFToast(
      context: context,
      variant: FToastVariant.primary,
      duration: const Duration(seconds: 2),
      builder: (context, entry) => const FToast(title: Text('已复制到剪贴板')),
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
          status: status,
          traffic: _traffic,
          trafficError: _trafficError,
          running: status.isRunning,
        ),
        _TokenHomeView.settings => Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _TokenSettingsPanel(
              profile: widget.profile,
              status: status,
              onReconnect: () =>
                  unawaited(widget.coreLifecycleService.repair()),
              onCopyDiagnostics: () => unawaited(_copyDiagnostics()),
              onCopyText: (value) => unawaited(_copyText(value)),
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
    required this.status,
    required this.traffic,
    required this.trafficError,
    required this.running,
  });

  final CoreRunStatus status;
  final Map<String, _TokenTrafficSnapshot> traffic;
  final String? trafficError;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final entries = traffic.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    var totalDownloadRate = 0.0;
    var totalUploadRate = 0.0;
    for (final entry in entries) {
      totalDownloadRate += entry.value.downloadBytesPerSecond ?? 0;
      totalUploadRate += entry.value.uploadBytesPerSecond ?? 0;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TokenStatusSummary(
          status: status,
          instanceCount: running ? entries.length : 0,
          downloadRate: totalDownloadRate,
          uploadRate: totalUploadRate,
          hasTrafficStats: entries.isNotEmpty,
        ),
        const SizedBox(height: 24),
        _TokenNetworkInstanceList(
          entries: entries,
          trafficError: trafficError,
          running: running,
        ),
      ],
    );
  }
}

class _TokenStatusSummary extends StatelessWidget {
  const _TokenStatusSummary({
    required this.status,
    required this.instanceCount,
    required this.downloadRate,
    required this.uploadRate,
    required this.hasTrafficStats,
  });

  final CoreRunStatus status;
  final int instanceCount;
  final double downloadRate;
  final double uploadRate;
  final bool hasTrafficStats;

  @override
  Widget build(BuildContext context) {
    final running = status.phase == CoreRunPhase.running;
    final error = status.phase == CoreRunPhase.error;
    final checking =
        status.phase == CoreRunPhase.checking ||
        status.phase == CoreRunPhase.repairing;
    final stopped =
        status.phase == CoreRunPhase.stopped ||
        status.phase == CoreRunPhase.signedOut;
    final needsAuthorization =
        status.phase == CoreRunPhase.needsElevation ||
        status.phase == CoreRunPhase.needsVpnPermission;

    final ringColor = error
        ? const Color(0xFFDC2626)
        : needsAuthorization
        ? const Color(0xFFF59E0B)
        : checking || stopped
        ? const Color(0xFF9CA3AF)
        : running
        ? const Color(0xFF16A34A)
        : const Color(0xFF2563EB);

    final bgColor = error
        ? const Color(0xFFFEE2E2)
        : needsAuthorization
        ? const Color(0xFFFEF3C7)
        : checking || stopped
        ? const Color(0xFFF3F4F6)
        : running
        ? const Color(0xFFF0FDF4)
        : const Color(0xFFDBEAFE);

    final borderColor = error
        ? const Color(0xFFFECACA)
        : needsAuthorization
        ? const Color(0xFFFDE68A)
        : checking || stopped
        ? const Color(0xFFE5E7EB)
        : running
        ? const Color(0xFFBBF7D0)
        : const Color(0xFFBFDBFE);

    final icon = error
        ? Icons.error_outline
        : needsAuthorization
        ? Icons.verified_user_outlined
        : checking
        ? Icons.sync
        : running
        ? Icons.check
        : Icons.power_settings_new;

    final title = error
        ? '连接异常'
        : needsAuthorization
        ? '需要授权'
        : checking
        ? '正在连接'
        : running
        ? '已在线'
        : '已断开';

    final subtitle = error
        ? status.lastError?.isNotEmpty == true
              ? status.lastError!
              : '连接引擎遇到问题'
        : needsAuthorization
        ? status.lastError?.isNotEmpty == true
              ? status.lastError!
              : status.message
        : running
        ? instanceCount > 0
              ? '$instanceCount 个网络实例'
              : '暂无网络实例'
        : status.message;

    final statusBody = Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: ringColor, width: 3),
            boxShadow: [
              BoxShadow(
                color: ringColor.withAlpha(20),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(child: Icon(icon, color: ringColor, size: 18)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF0F172A),
                  fontSize: 16,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF64748B),
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );

    final trafficStrip =
        hasTrafficStats && instanceCount > 0 && !error && !needsAuthorization
        ? HomeTrafficRateStrip(
            downloadRate: downloadRate,
            uploadRate: uploadRate,
          )
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withAlpha(6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (trafficStrip != null && constraints.maxWidth < 240) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                statusBody,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: trafficStrip),
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: statusBody),
              if (trafficStrip != null) ...[
                const SizedBox(width: 10),
                trafficStrip,
              ],
            ],
          );
        },
      ),
    );
  }
}

class _TokenSettingsPanel extends StatelessWidget {
  const _TokenSettingsPanel({
    required this.profile,
    required this.status,
    required this.onReconnect,
    required this.onCopyDiagnostics,
    required this.onCopyText,
    required this.onDisconnect,
    required this.onChangeToken,
    required this.onAccountLogin,
  });

  final TokenConnectionProfile profile;
  final CoreRunStatus status;
  final VoidCallback onReconnect;
  final VoidCallback onCopyDiagnostics;
  final ValueChanged<String> onCopyText;
  final VoidCallback onDisconnect;
  final VoidCallback onChangeToken;
  final VoidCallback onAccountLogin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = status.lastError?.trim();
    final engine = status.details?.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '连接',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 16),
        FCard.raw(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _phaseIcon(status.phase),
                      size: 18,
                      color: _phaseColor(status.phase),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        status.message,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                HomeSettingsInfoRow(
                  label: '设备 ID',
                  value: status.machineId ?? '等待注册',
                  onCopy: onCopyText,
                ),
                const SizedBox(height: 12),
                HomeSettingsInfoRow(
                  label: '连接引擎',
                  value: engine == null || engine.isEmpty ? '准备中' : engine,
                  onCopy: onCopyText,
                ),
                const SizedBox(height: 12),
                HomeSettingsInfoRow(
                  label: '控制服务器',
                  value: profile.configServer,
                  onCopy: onCopyText,
                ),
                if (error != null && error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F9FB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Text(
                      error,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _phaseColor(status.phase),
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
                      variant: .outline,
                      onPress: onReconnect,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh, size: 16),
                          SizedBox(width: 8),
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
                          SizedBox(width: 8),
                          Text('复制诊断'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          '登录方式',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 16),
        FCard.raw(
          child: FItemGroup(
            divider: .full,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              FItem.raw(
                prefix: const Icon(Icons.vpn_key_outlined),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '设备令牌',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF737373),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      profile.effectiveDisplayName,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF0F172A),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FButton(
              variant: .outline,
              onPress: onChangeToken,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.key_outlined, size: 16),
                  SizedBox(width: 8),
                  Text('更换令牌'),
                ],
              ),
            ),
            FButton(
              variant: .outline,
              onPress: onAccountLogin,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.login, size: 16),
                  SizedBox(width: 8),
                  Text('使用账号登录'),
                ],
              ),
            ),
            FButton(
              variant: .destructive,
              onPress: onDisconnect,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.power_settings_new, size: 16),
                  SizedBox(width: 8),
                  Text('断开连接'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TokenNetworkInstanceList extends StatelessWidget {
  const _TokenNetworkInstanceList({
    required this.entries,
    required this.trafficError,
    required this.running,
  });

  final List<MapEntry<String, _TokenTrafficSnapshot>> entries;
  final String? trafficError;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A).withAlpha(8),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.hub_outlined,
                    size: 18,
                    color: Color(0xFF334155),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '网络',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F172A),
                    fontSize: 18,
                  ),
                ),
              ],
            ),
            const Spacer(),
            const _TokenReadonlyHint(),
          ],
        ),
        const SizedBox(height: 16),
        if (!running)
          const _TokenNetworkInstanceEmpty(message: '连接建立后会显示本机网络实例。')
        else if (trafficError != null && trafficError!.isNotEmpty)
          _TokenNetworkInstanceEmpty(message: trafficError!)
        else if (entries.isEmpty)
          const _TokenNetworkInstanceEmpty(message: '暂无网络实例')
        else
          Column(
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _TokenNetworkInstanceTile(
                  runtimeName: entries[i].key,
                  snapshot: entries[i].value,
                ),
              ],
            ],
          ),
      ],
    );
  }
}

class _TokenReadonlyHint extends StatelessWidget {
  const _TokenReadonlyHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Text(
        '只读',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: const Color(0xFF64748B),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TokenNetworkInstanceEmpty extends StatelessWidget {
  const _TokenNetworkInstanceEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: _TokenMutedText(message),
      ),
    );
  }
}

class _TokenNetworkInstanceTile extends StatelessWidget {
  const _TokenNetworkInstanceTile({
    required this.runtimeName,
    required this.snapshot,
  });

  final String runtimeName;
  final _TokenTrafficSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloadRate = _formatTrafficRate(snapshot.downloadBytesPerSecond);
    final uploadRate = _formatTrafficRate(snapshot.uploadBytesPerSecond);

    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF16A34A),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          runtimeName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: const Color(0xFF0F172A),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const _TokenReadonlySwitch(value: true),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      const _TokenInstanceStateBadge(),
                      _RateBadge(icon: Icons.south_west, value: downloadRate),
                      _RateBadge(icon: Icons.north_east, value: uploadRate),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenReadonlySwitch extends StatelessWidget {
  const _TokenReadonlySwitch({required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '设备令牌连接由控制台下发，客户端仅展示状态。',
      excludeFromSemantics: true,
      child: FSwitch(value: value, enabled: false, onChange: null),
    );
  }
}

class _TokenInstanceStateBadge extends StatelessWidget {
  const _TokenInstanceStateBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFEFFDF4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 13,
            color: Color(0xFF16A34A),
          ),
          const SizedBox(width: 4),
          Text(
            '已连接',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: const Color(0xFF15803D),
              fontWeight: FontWeight.w800,
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
