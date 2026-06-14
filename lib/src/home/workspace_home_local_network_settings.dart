part of 'workspace_home_view.dart';

class _LocalNetworkSettingsViewport extends StatelessWidget {
  const _LocalNetworkSettingsViewport({
    super.key,
    required this.network,
    required this.node,
    required this.config,
    required this.loading,
    required this.error,
    required this.joinState,
    required this.onRetry,
  });

  final ConsoleNetwork network;
  final NetworkDevice? node;
  final NodeInstanceConfigView? config;
  final bool loading;
  final String? error;
  final _JoinNetworkState joinState;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final localNode = node;
    if (localNode == null) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return _NetworkDetailScrollViewport(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.hasBoundedHeight
                    ? constraints.maxHeight
                    : 0,
              ),
              child: const _StateMessage(message: '本机尚未加入此网络。'),
            ),
          );
        },
      );
    }
    if (loading && config == null) {
      return const Center(child: FCircularProgress());
    }
    if (error != null && config == null) {
      return _StateMessage(
        message: error!,
        action: FButton(
          variant: .outline,
          size: .sm,
          onPress: onRetry,
          child: const Text('重试'),
        ),
      );
    }
    final view = config;
    if (view == null) {
      return const _StateMessage(message: '正在读取本机设置...');
    }

    return _NetworkDetailScrollViewport(
      child: KeyedSubtree(
        key: const ValueKey<String>('network-detail-section-local'),
        child: _LocalNetworkSettingsPanel(
          network: network,
          node: localNode,
          config: view,
          loading: loading,
          error: error,
          joinState: joinState,
          onRetry: onRetry,
        ),
      ),
    );
  }
}

class _LocalNetworkSettingsPanel extends StatelessWidget {
  const _LocalNetworkSettingsPanel({
    required this.network,
    required this.node,
    required this.config,
    required this.loading,
    required this.error,
    required this.joinState,
    required this.onRetry,
  });

  final ConsoleNetwork network;
  final NetworkDevice node;
  final NodeInstanceConfigView config;
  final bool loading;
  final String? error;
  final _JoinNetworkState joinState;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final effective = config.effective;
    final ipv4 = effective.ipv4 ?? joinState.localIpv4 ?? node.ipv4 ?? '-';
    final hostname = effective.hostname ?? node.hostname.trim();
    final displayHostname = hostname.isEmpty ? node.displayLabel : hostname;
    final listenerProtocols = effective.listenerProtocols.isEmpty
        ? '未监听'
        : effective.listenerProtocols
              .map((protocol) => protocol.toUpperCase())
              .join(', ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (loading) ...[
          const Align(
            alignment: Alignment.centerLeft,
            child: SizedBox.square(
              dimension: 16,
              child: FCircularProgress(size: .sm),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (error != null) ...[
          _NetworkDetailNotice(message: error!),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FButton(
              variant: .outline,
              size: .sm,
              onPress: onRetry,
              child: const Text('重试'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        _NetworkDetailCard(
          title: '身份',
          children: [
            _NetworkInfoGrid(
              items: [
                _NetworkInfoItem(label: '虚拟 IP', value: ipv4),
                _NetworkInfoItem(label: '主机名', value: displayHostname),
                _NetworkInfoItem(label: '网络 CIDR', value: network.ipv4Cidr),
                _NetworkInfoItem(
                  label: '配置来源',
                  value: _configScopeLabel(config.configScope),
                ),
              ],
            ),
          ],
        ),
        _NetworkDetailCard(
          title: '配置状态',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _NetworkDetailMetricPill(
                  icon: Icons.task_alt_outlined,
                  label: '应用',
                  value: _applyStatusLabel(config.applyStatus),
                ),
                _NetworkDetailMetricPill(
                  icon: Icons.sync_problem_outlined,
                  label: '漂移',
                  value: _driftStatusLabel(config.driftStatus),
                ),
              ],
            ),
            if (config.lastApplyError?.isNotEmpty == true) ...[
              const SizedBox(height: 10),
              _NetworkDetailNotice(message: config.lastApplyError!),
            ],
          ],
        ),
        _NetworkDetailCard(
          title: '连接策略',
          children: [
            _NetworkInfoGrid(
              items: [
                _NetworkInfoItem(
                  label: 'P2P 策略',
                  value: _p2pModeLabel(effective.p2pMode),
                ),
                _NetworkInfoItem(label: '监听协议', value: listenerProtocols),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ConfigTogglePill(
                  label: 'Magic DNS',
                  enabled: effective.magicDnsEnabled,
                ),
                _ConfigTogglePill(label: 'No-TUN', enabled: effective.noTun),
                _ConfigTogglePill(
                  label: '系统转发',
                  enabled: effective.proxyForwardBySystem,
                ),
                _ConfigTogglePill(
                  label: '用户态协议栈',
                  enabled: effective.userspaceStack,
                ),
              ],
            ),
          ],
        ),
        _NetworkDetailCard(
          title: '子网路由',
          children: [
            _AssignedRoutePills(
              label: '本机负责',
              routes: config.assignedSubnetRoutes,
              emptyText: '未负责子网路由',
            ),
            const SizedBox(height: 12),
            _AssignedRoutePills(
              label: config.manualRoutesEnabled ? '手动接收' : '手动接收未启用',
              routes: config.manualSubnetRoutes,
              emptyText: '未接收手动子网路由',
            ),
          ],
        ),
      ],
    );
  }
}

class _NetworkDetailNotice extends StatelessWidget {
  const _NetworkDetailNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_outlined,
              size: 18,
              color: Color(0xFFD97706),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF92400E),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NetworkDetailCard extends StatelessWidget {
  const _NetworkDetailCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: const Color(0xFF0F172A),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _NetworkInfoGrid extends StatelessWidget {
  const _NetworkInfoGrid({required this.items});

  final List<_NetworkInfoItem> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 520;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final item in items)
              SizedBox(
                width: twoColumns
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth,
                child: item,
              ),
          ],
        );
      },
    );
  }
}

class _NetworkInfoItem extends StatelessWidget {
  const _NetworkInfoItem({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final text = value?.trim().isNotEmpty == true ? value!.trim() : '-';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF94A3B8),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        SelectableTextHitBoundary(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF0F172A),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _NetworkDetailMetricPill extends StatelessWidget {
  const _NetworkDetailMetricPill({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: const Color(0xFF64748B)),
              const SizedBox(width: 6),
              Text(
                '$label：',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF94A3B8),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF0F172A),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConfigTogglePill extends StatelessWidget {
  const _ConfigTogglePill({required this.label, required this.enabled});

  final String label;
  final bool? enabled;

  @override
  Widget build(BuildContext context) {
    final active = enabled == true;
    final color = active ? const Color(0xFF16A34A) : const Color(0xFF64748B);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? const Color(0xFFF0FDF4) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? const Color(0xFFBBF7D0) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active ? Icons.check : Icons.remove, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              '$label ${active ? '启用' : '关闭'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignedRoutePills extends StatelessWidget {
  const _AssignedRoutePills({
    required this.label,
    required this.routes,
    required this.emptyText,
  });

  final String label;
  final List<AssignedSubnetRoute> routes;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: const Color(0xFF94A3B8),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        if (routes.isEmpty)
          Text(
            emptyText,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final route in routes)
                _RouteTextPill(
                  key: ValueKey<String>('assigned-subnet-route-${route.id}'),
                  text: _assignedRouteText(route),
                ),
            ],
          ),
      ],
    );
  }
}

class _RouteTextPill extends StatelessWidget {
  const _RouteTextPill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: SelectableTextHitBoundary(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF0F172A),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

String _assignedRouteText(AssignedSubnetRoute route) {
  final mapped = route.mappedCidr?.trim();
  if (mapped == null || mapped.isEmpty) {
    return route.cidr;
  }
  return '${route.cidr} -> $mapped';
}

String _configScopeLabel(String value) {
  return switch (value.toLowerCase()) {
    'customized' => '本机覆盖',
    'inherited' => '继承网络默认',
    '' => '-',
    _ => value,
  };
}

String _applyStatusLabel(String value) {
  return switch (value.toLowerCase()) {
    'applied' || 'config_applied' => '已应用',
    'pending' || 'queued' => '等待应用',
    'applying' || 'running' => '应用中',
    'error' || 'failed' => '应用失败',
    '' => '-',
    _ => value,
  };
}

String _driftStatusLabel(String value) {
  return switch (value.toLowerCase()) {
    'in_sync' || 'synced' || 'clean' => '一致',
    'drifted' || 'out_of_sync' => '有漂移',
    'unknown' => '未知',
    '' => '-',
    _ => value,
  };
}

String _p2pModeLabel(String? value) {
  return switch (value?.toLowerCase()) {
    'automatic' => '自动',
    'relay_preferred' => '优先中继',
    'p2p_only' => '仅 P2P',
    null || '' => '-',
    _ => value!,
  };
}
