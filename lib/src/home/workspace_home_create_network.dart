part of 'workspace_home_view.dart';

class _CreateNetworkForm extends StatelessWidget {
  const _CreateNetworkForm({
    required this.nameController,
    required this.ipv4CidrController,
    required this.selectedRegionCode,
    required this.regions,
    required this.loadingRegions,
    required this.creating,
    required this.error,
    required this.onNameChanged,
    required this.onIPv4CidrChanged,
    required this.onRegionChanged,
    required this.onCreate,
    required this.onRetryRegions,
  });

  final TextEditingController nameController;
  final TextEditingController ipv4CidrController;
  final String? selectedRegionCode;
  final List<ConsoleRegion> regions;
  final bool loadingRegions;
  final bool creating;
  final String? error;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onIPv4CidrChanged;
  final ValueChanged<String?> onRegionChanged;
  final Future<void> Function() onCreate;
  final Future<void> Function() onRetryRegions;

  @override
  Widget build(BuildContext context) {
    final canCreate = regions.isNotEmpty && !loadingRegions && !creating;
    final hasError = error != null && error!.isNotEmpty;
    final noRegions = !loadingRegions && regions.isEmpty;
    final ipv4Cidr = ipv4CidrController.text;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _FormFieldBlock(
          icon: Icons.language_outlined,
          label: '网络名称',
          description: '用于识别该网络的名称，如「办公网」。',
          child: FTextField(
            control: FTextFieldControl.managed(
              controller: nameController,
              onChange: (value) => onNameChanged(value.text),
            ),
            size: .sm,
          ),
        ),
        const SizedBox(height: 16),
        _FormFieldBlock(
          icon: Icons.router_outlined,
          label: '网络地址范围',
          description: '分配该网络的 IPv4 网段，设备加入后自动获取 IP。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FTextField(
                control: FTextFieldControl.managed(
                  controller: ipv4CidrController,
                  onChange: (value) => onIPv4CidrChanged(value.text),
                ),
                size: .sm,
                hint: '10.144.0.0/16',
                keyboardType: TextInputType.text,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CidrPresetChip(
                    label: '10.144.0.0/16',
                    value: '10.144.0.0/16',
                    active: ipv4Cidr == '10.144.0.0/16',
                    onTap: onIPv4CidrChanged,
                  ),
                  _CidrPresetChip(
                    label: '192.168.0.0/24',
                    value: '192.168.0.0/24',
                    active: ipv4Cidr == '192.168.0.0/24',
                    onTap: onIPv4CidrChanged,
                  ),
                  _CidrPresetChip(
                    label: '172.16.0.0/16',
                    value: '172.16.0.0/16',
                    active: ipv4Cidr == '172.16.0.0/16',
                    onTap: onIPv4CidrChanged,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _FormFieldBlock(
          icon: Icons.place_outlined,
          label: '区域',
          description: '选择网络所属的区域，影响数据路由路径。',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: FSelect<String>(
                  key: ValueKey<String?>(selectedRegionCode),
                  control: FSelectControl.lifted(
                    value: selectedRegionCode,
                    onChange: onRegionChanged,
                  ),
                  size: .sm,
                  items: {
                    for (final region in regions)
                      region.displayName: region.code,
                  },
                  enabled: !loadingRegions && regions.isNotEmpty,
                ),
              ),
              const SizedBox(width: 8),
              FButton(
                variant: .ghost,
                size: .sm,
                onPress: loadingRegions
                    ? null
                    : () => unawaited(onRetryRegions()),
                child: const Icon(Icons.refresh, size: 16),
              ),
            ],
          ),
        ),
        if (loadingRegions) ...[
          const SizedBox(height: 16),
          const Row(
            children: [
              FCircularProgress(size: .sm),
              SizedBox(width: 8),
              Text('正在读取可用区域...'),
            ],
          ),
        ],
        if (noRegions || hasError) ...[
          const SizedBox(height: 20),
          _ErrorBanner(message: noRegions ? '当前没有可用区域，暂时无法创建网络。' : error!),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FButton(
            onPress: canCreate ? () => unawaited(onCreate()) : null,
            child: creating
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FCircularProgress(size: .xs),
                      SizedBox(width: 8),
                      Text('正在创建...'),
                    ],
                  )
                : const Text('创建网络'),
          ),
        ),
      ],
    );
  }
}

class _FormFieldBlock extends StatelessWidget {
  const _FormFieldBlock({
    required this.icon,
    required this.label,
    required this.description,
    required this.child,
  });

  final IconData icon;
  final String label;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: const Color(0xFF64748B)),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: const Color(0xFF334155),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: const Color(0xFF94A3B8),
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _CidrPresetChip extends StatelessWidget {
  const _CidrPresetChip({
    required this.label,
    required this.value,
    required this.active,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool active;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onTap(value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFE2E8F0) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? const Color(0xFFCBD5E1) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: active ? const Color(0xFF1E293B) : const Color(0xFF475569),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 4,
              decoration: const BoxDecoration(
                color: Color(0xFFFCA5A5),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(8),
                  bottomLeft: Radius.circular(8),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 16,
                      color: Color(0xFFEF4444),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        message,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFB91C1C),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateNetworkPanel extends StatelessWidget {
  const _CreateNetworkPanel({
    required this.nameController,
    required this.ipv4CidrController,
    required this.selectedRegionCode,
    required this.regions,
    required this.loadingRegions,
    required this.creating,
    required this.error,
    required this.onNameChanged,
    required this.onIPv4CidrChanged,
    required this.onRegionChanged,
    required this.onCreate,
    required this.onRetryRegions,
  });

  final TextEditingController nameController;
  final TextEditingController ipv4CidrController;
  final String? selectedRegionCode;
  final List<ConsoleRegion> regions;
  final bool loadingRegions;
  final bool creating;
  final String? error;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onIPv4CidrChanged;
  final ValueChanged<String?> onRegionChanged;
  final Future<void> Function() onCreate;
  final Future<void> Function() onRetryRegions;

  @override
  Widget build(BuildContext context) {
    return FCard.raw(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('创建第一个网络', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '当前工作区还没有网络。先创建网络，然后把本机设备加入进去。',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF737373)),
            ),
            const SizedBox(height: 24),
            _CreateNetworkForm(
              nameController: nameController,
              ipv4CidrController: ipv4CidrController,
              selectedRegionCode: selectedRegionCode,
              regions: regions,
              loadingRegions: loadingRegions,
              creating: creating,
              error: error,
              onNameChanged: onNameChanged,
              onIPv4CidrChanged: onIPv4CidrChanged,
              onRegionChanged: onRegionChanged,
              onCreate: onCreate,
              onRetryRegions: onRetryRegions,
            ),
          ],
        ),
      ),
    );
  }
}
