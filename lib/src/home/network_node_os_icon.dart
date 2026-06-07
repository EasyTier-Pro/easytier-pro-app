part of 'network_node_list_panel.dart';

class _NodeOsIcon extends StatelessWidget {
  const _NodeOsIcon({
    required this.os,
    required this.osVersion,
    required this.osDistribution,
    required this.online,
    required this.isLocal,
  });

  final String os;
  final String osVersion;
  final String osDistribution;
  final bool online;
  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    return DeviceOsIcon(
      os: os,
      osVersion: osVersion,
      osDistribution: osDistribution,
      online: online,
      isLocal: isLocal,
    );
  }
}
