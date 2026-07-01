import 'package:flutter/material.dart';

class HomeNetworkListSection extends StatelessWidget {
  const HomeNetworkListSection({
    super.key,
    this.title = '网络',
    this.icon = Icons.hub_outlined,
    this.trailing,
    this.empty,
    required this.children,
  });

  final String title;
  final IconData icon;
  final Widget? trailing;
  final Widget? empty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeNetworkListHeader(title: title, icon: icon, trailing: trailing),
        const SizedBox(height: 16),
        HomeNetworkListItems(empty: empty, children: children),
      ],
    );
  }
}

class HomeNetworkListHeader extends StatelessWidget {
  const HomeNetworkListHeader({
    super.key,
    required this.title,
    required this.icon,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
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
              child: Icon(icon, size: 18, color: const Color(0xFF334155)),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF0F172A),
                fontSize: 18,
              ),
            ),
          ],
        ),
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}

class HomeNetworkListItems extends StatelessWidget {
  const HomeNetworkListItems({super.key, required this.children, this.empty});

  final List<Widget> children;
  final Widget? empty;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return empty ?? const SizedBox.shrink();
    }

    return Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
  }
}
