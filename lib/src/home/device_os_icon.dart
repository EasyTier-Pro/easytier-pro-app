import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class DeviceOsIcon extends StatelessWidget {
  const DeviceOsIcon({
    super.key,
    required this.os,
    required this.osVersion,
    required this.osDistribution,
    required this.online,
    this.isLocal = false,
    this.dimension = 32,
  });

  final String os;
  final String osVersion;
  final String osDistribution;
  final bool online;
  final bool isLocal;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final style = _osIconStyle(os, osDistribution);
    final label = _osLabel(os, osVersion, osDistribution);
    final borderColor = isLocal
        ? const Color(0xFF2563EB)
        : online
        ? const Color(0xFFBBF7D0)
        : const Color(0xFFE5E7EB);
    final statusSize = (dimension * 0.25).clamp(6.0, 9.0);

    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: SizedBox.square(
        dimension: dimension,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: dimension,
              height: dimension,
              decoration: BoxDecoration(
                color: style.backgroundColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: borderColor,
                  width: isLocal ? 1.5 : 1,
                ),
              ),
              child: Center(
                child: style.faIcon == null
                    ? Icon(
                        style.materialIcon,
                        size: dimension * 0.53,
                        color: style.iconColor,
                      )
                    : FaIcon(
                        style.faIcon,
                        size: dimension * 0.53,
                        color: style.iconColor,
                      ),
              ),
            ),
            Positioned(
              right: 1,
              bottom: 1,
              child: Container(
                width: statusSize,
                height: statusSize,
                decoration: BoxDecoration(
                  color: online
                      ? const Color(0xFF16A34A)
                      : const Color(0xFF9CA3AF),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceOsIconStyle {
  const _DeviceOsIconStyle({
    this.faIcon,
    this.materialIcon,
    required this.iconColor,
    required this.backgroundColor,
  });

  final FaIconData? faIcon;
  final IconData? materialIcon;
  final Color iconColor;
  final Color backgroundColor;
}

_DeviceOsIconStyle _osIconStyle(String os, String distribution) {
  final value = '${os.trim()} ${distribution.trim()}'.toLowerCase();
  if (value.contains('windows') ||
      value.contains('win32') ||
      value.contains('win64') ||
      value == 'win') {
    return const _DeviceOsIconStyle(
      faIcon: FontAwesomeIcons.windows,
      iconColor: Color(0xFF2563EB),
      backgroundColor: Color(0xFFEFF6FF),
    );
  }
  if (value.contains('ios') ||
      value.contains('iphone') ||
      value.contains('ipad')) {
    return const _DeviceOsIconStyle(
      faIcon: FontAwesomeIcons.apple,
      iconColor: Color(0xFF7C3AED),
      backgroundColor: Color(0xFFF5F3FF),
    );
  }
  if (value.contains('mac') || value.contains('darwin')) {
    return const _DeviceOsIconStyle(
      faIcon: FontAwesomeIcons.apple,
      iconColor: Color(0xFF475569),
      backgroundColor: Color(0xFFF8FAFC),
    );
  }
  if (value.contains('android')) {
    return const _DeviceOsIconStyle(
      faIcon: FontAwesomeIcons.android,
      iconColor: Color(0xFF16A34A),
      backgroundColor: Color(0xFFF0FDF4),
    );
  }
  if (value.contains('linux') ||
      value.contains('ubuntu') ||
      value.contains('debian') ||
      value.contains('centos') ||
      value.contains('fedora') ||
      value.contains('arch')) {
    return const _DeviceOsIconStyle(
      faIcon: FontAwesomeIcons.linux,
      iconColor: Color(0xFF0F766E),
      backgroundColor: Color(0xFFF0FDFA),
    );
  }
  return const _DeviceOsIconStyle(
    materialIcon: Icons.devices_other_outlined,
    iconColor: Color(0xFF64748B),
    backgroundColor: Color(0xFFF8FAFC),
  );
}

String _osLabel(String os, String version, String distribution) {
  final parts = <String>[
    if (distribution.trim().isNotEmpty) distribution.trim(),
    if (version.trim().isNotEmpty) version.trim(),
    if (os.trim().isNotEmpty) os.trim(),
  ];
  return parts.isEmpty ? '未知系统' : parts.join(' · ');
}
