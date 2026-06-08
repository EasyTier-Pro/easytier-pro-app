part of 'workspace_home_view.dart';

class _ManagedDeviceRow extends StatelessWidget {
  const _ManagedDeviceRow({
    super.key,
    required this.device,
    required this.localMachineId,
  });

  final ManagedDevice device;
  final String localMachineId;

  @override
  Widget build(BuildContext context) {
    final status = _managedDeviceStatus(device);
    final meta = _managedDeviceMeta(device);
    final isLocal =
        localMachineId.isNotEmpty && localMachineId == device.machineId.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          DeviceOsIcon(
            os: device.os,
            osVersion: device.osVersion,
            osDistribution: device.osDistribution,
            online: device.online,
            isLocal: isLocal,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  device.displayLabel,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF0F172A),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF94A3B8),
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ManagedDeviceStatusChip(status: status),
        ],
      ),
    );
  }
}

class _ManagedDeviceStatus {
  const _ManagedDeviceStatus({required this.label, required this.color});

  final String label;
  final Color color;
}

class _ManagedDeviceStatusChip extends StatelessWidget {
  const _ManagedDeviceStatusChip({required this.status});

  final _ManagedDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: status.color.withAlpha(12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: status.color.withAlpha(35)),
      ),
      child: Text(
        status.label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: status.color,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

_ManagedDeviceStatus _managedDeviceStatus(ManagedDevice device) {
  if (!device.approved) {
    return _ManagedDeviceStatus(
      label: _approvalLabel(device),
      color: const Color(0xFFD97706),
    );
  }

  if (device.online) {
    return const _ManagedDeviceStatus(label: '在线', color: Color(0xFF16A34A));
  }

  return const _ManagedDeviceStatus(label: '离线', color: Color(0xFF64748B));
}

String _managedDeviceMeta(ManagedDevice device) {
  final osParts = <String>[
    device.osDistribution.trim(),
    device.osVersion.trim(),
  ].where((part) => part.isNotEmpty).toList(growable: false);
  final os = osParts.isNotEmpty ? osParts.join(' ') : device.os.trim();
  final hostname = device.hostname.trim();
  final showHostname =
      hostname.isNotEmpty && hostname != device.displayLabel.trim();
  final parts = <String>[
    if (showHostname) hostname,
    if (os.isNotEmpty) os,
    _shortId(device.machineId),
  ];
  return parts.join(' · ');
}
