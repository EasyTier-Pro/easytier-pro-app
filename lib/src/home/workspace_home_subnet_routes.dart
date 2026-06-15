part of 'workspace_home_view.dart';

class _NetworkSubnetRouteViewport extends StatelessWidget {
  const _NetworkSubnetRouteViewport({
    super.key,
    required this.routes,
    required this.loading,
    required this.error,
    required this.onRetry,
    this.scrollDeltaCoordinator,
    this.onStaticContentShown,
  });

  final NetworkSubnetRouteList? routes;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final AppScrollDeltaCoordinator? scrollDeltaCoordinator;
  final VoidCallback? onStaticContentShown;

  @override
  Widget build(BuildContext context) {
    if (loading && routes == null) {
      return _NetworkDetailStaticViewport(
        onShown: onStaticContentShown,
        child: const Center(child: FCircularProgress()),
      );
    }
    if (error != null && routes == null) {
      return _NetworkDetailStaticViewport(
        onShown: onStaticContentShown,
        child: _StateMessage(
          message: error!,
          action: FButton(
            variant: .outline,
            size: .sm,
            onPress: onRetry,
            child: const Text('重试'),
          ),
        ),
      );
    }

    final routeList = routes;
    if (routeList == null) {
      return _NetworkDetailStaticViewport(
        onShown: onStaticContentShown,
        child: const _StateMessage(message: '正在读取子网路由...'),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return _NetworkDetailScrollViewport(
          scrollDeltaCoordinator: scrollDeltaCoordinator,
          child: _NetworkSubnetRoutePanel(
            routes: routeList,
            loading: loading,
            error: error,
            onRetry: onRetry,
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
        );
      },
    );
  }
}

class _NetworkSubnetRoutePanel extends StatelessWidget {
  const _NetworkSubnetRoutePanel({
    required this.routes,
    required this.loading,
    required this.error,
    required this.onRetry,
    this.minHeight = 0,
  });

  final NetworkSubnetRouteList routes;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    if (routes.routes.isEmpty) {
      return ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
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
            const NetworkDetailEmptyState(message: '暂无子网路由'),
          ],
        ),
      );
    }

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
        for (final route in routes.routes)
          _NetworkSubnetRouteCard(
            key: ValueKey<String>('network-subnet-route-${route.id}'),
            route: route,
          ),
      ],
    );
  }
}

class _NetworkSubnetRouteCard extends StatelessWidget {
  const _NetworkSubnetRouteCard({super.key, required this.route});

  final NetworkSubnetRoute route;

  @override
  Widget build(BuildContext context) {
    final routerOnline = route.nodes
        .where((node) => node.status.toLowerCase() == 'online')
        .length;
    final mapped = route.mappedCidr?.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.route_outlined,
                    size: 18,
                    color: Color(0xFF334155),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableTextHitBoundary(
                      child: Text(
                        route.cidr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: const Color(0xFF0F172A),
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                mapped == null || mapped.isEmpty ? '无地址映射' : '映射为 $mapped',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
              ),
              const SizedBox(height: 12),
              _NetworkDetailMetricPill(
                icon: Icons.router_outlined,
                label: '负责节点',
                value: '${route.nodes.length} 个 · $routerOnline 在线',
              ),
              if (route.nodes.isNotEmpty) ...[
                const SizedBox(height: 12),
                _SubnetRouteNodeLine(label: '路由器', nodes: route.nodes),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SubnetRouteNodeLine extends StatelessWidget {
  const _SubnetRouteNodeLine({required this.label, required this.nodes});

  final String label;
  final List<SubnetRouteNodeSummary> nodes;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label：${nodes.map((node) => node.displayLabel).join(', ')}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: const Color(0xFF94A3B8)),
    );
  }
}
