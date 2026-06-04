part of 'workspace_home_view.dart';

class _CreateNetworkForm extends StatelessWidget {
  const _CreateNetworkForm({
    required this.name,
    required this.ipv4Cidr,
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

  final String name;
  final String ipv4Cidr;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 480;
            final nameField = FTextField(
              key: ValueKey<String>(name),
              control: FTextFieldControl.managed(
                initial: TextEditingValue(text: name),
                onChange: (value) => onNameChanged(value.text),
              ),
              size: .sm,
              label: const Text('网络名称'),
            );
            final cidrField = FTextField(
              key: ValueKey<String>('cidr:$ipv4Cidr'),
              control: FTextFieldControl.managed(
                initial: TextEditingValue(text: ipv4Cidr),
                onChange: (value) => onIPv4CidrChanged(value.text),
              ),
              size: .sm,
              label: const Text('网络地址范围'),
              hint: '10.144.0.0/16',
              keyboardType: TextInputType.text,
            );
            final regionField = FSelect<String>(
              key: ValueKey<String?>(selectedRegionCode),
              control: FSelectControl.lifted(
                value: selectedRegionCode,
                onChange: onRegionChanged,
              ),
              size: .sm,
              label: const Text('区域'),
              items: {
                for (final region in regions) region.displayName: region.code,
              },
              enabled: !loadingRegions && regions.isNotEmpty,
            );
            if (!wide) {
              return Column(
                children: [
                  nameField,
                  const SizedBox(height: 12),
                  cidrField,
                  const SizedBox(height: 12),
                  regionField,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: nameField),
                const SizedBox(width: 12),
                Expanded(child: cidrField),
                const SizedBox(width: 12),
                Expanded(child: regionField),
              ],
            );
          },
        ),
        if (loadingRegions) ...[
          const SizedBox(height: 12),
          const Row(
            children: [
              FCircularProgress(size: .sm),
              SizedBox(width: 8),
              Text('正在读取可用区域...'),
            ],
          ),
        ],
        if (!loadingRegions && regions.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '当前没有可用区域，暂时无法创建网络。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFFDC2626)),
          ),
        ],
        if (error != null && error!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            error!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFFDC2626)),
          ),
        ],
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FButton(
              onPress: canCreate ? () => unawaited(onCreate()) : null,
              child: Text(creating ? '正在创建...' : '创建网络'),
            ),
            FButton(
              variant: .outline,
              onPress: loadingRegions
                  ? null
                  : () => unawaited(onRetryRegions()),
              child: const Text('刷新区域'),
            ),
          ],
        ),
      ],
    );
  }
}

class _CreateNetworkPanel extends StatelessWidget {
  const _CreateNetworkPanel({
    required this.name,
    required this.ipv4Cidr,
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

  final String name;
  final String ipv4Cidr;
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
            const SizedBox(height: 18),
            _CreateNetworkForm(
              name: name,
              ipv4Cidr: ipv4Cidr,
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
