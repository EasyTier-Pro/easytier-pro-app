import 'dart:async';

import 'package:forui/forui.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/auth/auth_gate.dart';
import 'src/auth/console_auth_service.dart';

const Color _appBackground = Color(0xFFF8F9FB);
const Color _cardBackground = Color(0xFFFFFFFF);
const Color _foreground = Color(0xFF0A0A0A);
const Color _mutedForeground = Color(0xFF5E5E5E);
const Color _border = Color(0xFFE5E7EB);
const Color _brandCoral = Color(0xFFFF5530);
const Color _brandBlue = Color(0xFF1456F0);
const Color _brandPurple = Color(0xFFA855F7);
const Color _success = Color(0xFF10B981);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final authService = ConsoleAuthService(
    tokenStore: OAuthTokenStore(preferences),
  );

  runApp(MyApp(authService: authService));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.authService});

  final AuthService authService;

  @override
  Widget build(BuildContext context) {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: _foreground,
          brightness: Brightness.light,
        ).copyWith(
          primary: _foreground,
          onPrimary: Colors.white,
          secondary: _appBackground,
          surface: _cardBackground,
          onSurface: _foreground,
          outline: _border,
          tertiary: _brandCoral,
        );

    return MaterialApp(
          ),
        );
      },
    );
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader({required this.session, required this.onLogout});

  final AuthSession? session;
  final Future<void> Function()? onLogout;

  @override
  Widget build(BuildContext context) {
    final user = session?.user;
    final isOnline = user != null;

    return Material(
      color: _cardBackground,
      child: Container(
        height: 52,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showMetrics = constraints.maxWidth >= 720;
            final showUserName = constraints.maxWidth >= 560;

            return Row(
              children: [
                const _BrandMark(size: 28),
                const SizedBox(width: 10),
                const Flexible(
                  child: Text(
                    'EasyTier Pro',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _foreground,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                const Spacer(),
                _HeaderMetric(
                  color: isOnline ? _success : const Color(0xFFB8BDC7),
                  label: isOnline ? '在线' : '离线',
                ),
                if (isOnline && showMetrics) ...[
                  const SizedBox(width: 14),
                  _HeaderMetric(icon: Icons.group_outlined, label: '设备'),
                  const SizedBox(width: 14),
                  _HeaderMetric(icon: Icons.arrow_downward_rounded, label: '—'),
                  const SizedBox(width: 10),
                  _HeaderMetric(icon: Icons.arrow_upward_rounded, label: '—'),
                ],
                if (user != null) ...[
                  const SizedBox(width: 14),
                  _UserMenu(
                    user: user,
                    onLogout: onLogout,
                    showName: showUserName,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size / 2),
        border: Border.all(color: _foreground, width: 1.4),
      ),
      alignment: Alignment.center,
      child: Text(
        'E',
        style: TextStyle(
          color: _foreground,
          fontSize: size * 0.43,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({this.color, this.icon, required this.label});

  final Color? color;
  final IconData? icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final iconData = icon;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (color != null)
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          )
        else if (iconData != null)
          Icon(iconData, size: 15, color: _mutedForeground),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: _mutedForeground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _UserMenu extends StatelessWidget {
  const _UserMenu({
    required this.user,
    required this.onLogout,
    required this.showName,
  });

  final ConsoleUser user;
  final Future<void> Function()? onLogout;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '用户菜单',
      offset: const Offset(0, 10),
      onSelected: (value) {
        if (value == 'logout') {
          final logout = onLogout;
          if (logout != null) {
            unawaited(logout());
          }
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem<String>(value: 'logout', child: Text('退出登录')),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AvatarLabel(name: user.effectiveName, size: 30),
          if (showName) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                user.effectiveName.isEmpty ? '用户' : user.effectiveName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LoginRequiredView extends StatelessWidget {
  const _LoginRequiredView({super.key, required this.onLogin});

  final Future<void> Function() onLogin;

  @override
  Widget build(BuildContext context) {
    return _AuthShell(
      accentColor: _brandCoral,
      eyebrow: '控制台认证',
      title: '登录 EasyTier Pro',
      description: '使用控制台账号完成设备授权，登录后即可读取你的用户和工作空间信息。',
      action: FButton(
        mainAxisSize: MainAxisSize.min,
        onPress: () => unawaited(onLogin()),
        prefix: const Icon(Icons.login_rounded, size: 18),
        child: const Text('登录控制台'),
      ),
      detail: const _InfoStrip(
        icon: Icons.verified_user_outlined,
        text: '认证由 EasyTier Pro 控制台完成，本客户端不会保存账号密码。',
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _AuthShell(
      accentColor: _brandBlue,
      eyebrow: '正在准备',
      title: '连接控制台会话',
      description: message,
      action: const FCircularProgress(size: FCircularProgressSizeVariant.xl),
      detail: const _InfoStrip(
        icon: Icons.sync_rounded,
        text: '正在检查本地令牌状态，请稍候。',
      ),
    );
  }
}

class _DeviceAuthView extends StatelessWidget {
  const _DeviceAuthView({
    super.key,
    required this.statusMessage,
    required this.userCode,
    required this.onOpenBrowser,
  });

  final String? statusMessage;
  final String? userCode;
  final VoidCallback? onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    return _AuthShell(
      accentColor: _brandPurple,
      eyebrow: '设备授权',
      title: '在浏览器中批准登录',
      description: statusMessage ?? '请在浏览器中完成授权，授权完成后会自动返回应用。',
      action: FButton(
        mainAxisSize: MainAxisSize.min,
        onPress: onOpenBrowser,
        prefix: const Icon(Icons.open_in_browser_rounded, size: 18),
        child: const Text('重新打开浏览器'),
      ),
      detail: _DeviceCodeStrip(userCode: userCode),
    );
  }
}

class _AuthShell extends StatelessWidget {
  const _AuthShell({
    required this.accentColor,
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.action,
    required this.detail,
  });

  final Color accentColor;
  final String eyebrow;
  final String title;
  final String description;
  final Widget action;
  final Widget detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: _AppCard(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 560;
                final content = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      eyebrow,
                      style: const TextStyle(
                        color: _mutedForeground,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      description,
                      style: const TextStyle(
                        color: _mutedForeground,
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 18),
                    detail,
                    const SizedBox(height: 20),
                    action,
                  ],
                );

                return Flex(
                  direction: compact ? Axis.vertical : Axis.horizontal,
                  crossAxisAlignment: compact
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    _AccentBadge(color: accentColor),
                    SizedBox(width: compact ? 0 : 20, height: compact ? 18 : 0),
                    if (compact) content else Expanded(child: content),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AccentBadge extends StatelessWidget {
  const _AccentBadge({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Icon(Icons.hub_outlined, color: color, size: 36),
    );
  }
}

class _AppCard extends StatelessWidget {
  const _AppCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => FCard.raw(child: child);
}

class _InfoStrip extends StatelessWidget {
  const _InfoStrip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _appBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: _mutedForeground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: _mutedForeground, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceCodeStrip extends StatelessWidget {
  const _DeviceCodeStrip({required this.userCode});

  final String? userCode;

  @override
  Widget build(BuildContext context) {
    final code = userCode;
    if (code == null || code.isEmpty) {
      return const _InfoStrip(
        icon: Icons.schedule_rounded,
        text: '正在等待控制台批准授权。',
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _appBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          const Icon(Icons.password_rounded, size: 18, color: _mutedForeground),
          const SizedBox(width: 10),
          const Text(
            '验证码',
            style: TextStyle(color: _mutedForeground, fontSize: 12),
          ),
          const Spacer(),
          SelectableText(
            code,
            style: const TextStyle(
              color: _foreground,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceHomeView extends StatefulWidget {
  const _WorkspaceHomeView({
    required this.authService,
    required this.session,
    required this.onLogout,
    required this.onShowHelloWorld,
  });

  final AuthService authService;
  final AuthSession session;
  final Future<void> Function() onLogout;
  final VoidCallback onShowHelloWorld;

  @override
  State<_WorkspaceHomeView> createState() => _WorkspaceHomeViewState();
}

class _WorkspaceHomeViewState extends State<_WorkspaceHomeView> {
  List<ConsoleNetwork> _networks = const <ConsoleNetwork>[];
  List<NetworkDevice> _devices = const <NetworkDevice>[];
  String? _selectedNetworkId;
  String? _networkError;
  String? _deviceError;
  bool _isLoadingNetworks = false;
  bool _isLoadingDevices = false;
  int _networkRequestId = 0;
  int _deviceRequestId = 0;

  ConsoleWorkspace? get _workspace => widget.session.user.currentWorkspace;

  @override
  void initState() {
    super.initState();
    unawaited(_loadNetworks());
  }

  Future<void> _loadNetworks() async {
    final workspace = _workspace;
    if (workspace == null) {
      setState(() {
        _networkError = '当前账号未关联工作区。';
        _networks = const <ConsoleNetwork>[];
        _selectedNetworkId = null;
      });
      return;
    }

    final requestId = ++_networkRequestId;
    setState(() {
      _isLoadingNetworks = true;
      _networkError = null;
    });

    try {
      final networks = await widget.authService.fetchNetworks(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
      );

      if (!mounted || requestId != _networkRequestId) {
        return;
      }

      final selectedStillExists =
          _selectedNetworkId != null &&
          networks.any((network) => network.id == _selectedNetworkId);
      final selectedId = selectedStillExists
          ? _selectedNetworkId
          : (networks.isEmpty ? null : networks.first.id);

      setState(() {
        _networks = networks;
        _selectedNetworkId = selectedId;
        _isLoadingNetworks = false;
      });

      if (selectedId != null) {
        await _loadDevices(selectedId);
      } else {
        setState(() {
          _devices = const <NetworkDevice>[];
          _deviceError = null;
        });
      }
    } catch (error) {
      if (!mounted || requestId != _networkRequestId) {
        return;
      }
      setState(() {
        _isLoadingNetworks = false;
        _networkError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _loadDevices(String networkId) async {
    final workspace = _workspace;
    if (workspace == null) {
      return;
    }

    final requestId = ++_deviceRequestId;
    setState(() {
      _isLoadingDevices = true;
      _deviceError = null;
    });

    try {
      final devices = await widget.authService.fetchNetworkDevices(
        accessToken: widget.session.tokenSet.accessToken,
        workspaceId: workspace.id,
        networkId: networkId,
      );

      if (!mounted || requestId != _deviceRequestId) {
        return;
      }

      setState(() {
        _devices = devices;
        _isLoadingDevices = false;
      });
    } catch (error) {
      if (!mounted || requestId != _deviceRequestId) {
        return;
      }
      setState(() {
        _isLoadingDevices = false;
        _deviceError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _selectNetwork(String networkId) {
    if (_selectedNetworkId == networkId) {
      return;
    }

    setState(() {
      _selectedNetworkId = networkId;
    });
    unawaited(_loadDevices(networkId));
  }

  @override
  Widget build(BuildContext context) {
    ConsoleNetwork? selectedNetwork;
    for (final network in _networks) {
      if (network.id == _selectedNetworkId) {
        selectedNetwork = network;
        break;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        if (compact) {
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _WorkspaceHero(session: widget.session, workspace: _workspace),
              const SizedBox(height: 12),
              SizedBox(
                height: 240,
                child: _NetworkListCard(
                  networks: _networks,
                  selectedNetworkId: _selectedNetworkId,
                  isLoading: _isLoadingNetworks,
                  error: _networkError,
                  onRetry: _loadNetworks,
                  onSelect: _selectNetwork,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 360,
                child: _DevicePanelCard(
                  selectedNetwork: selectedNetwork,
                  devices: _devices,
                  isLoading: _isLoadingDevices,
                  error: _deviceError,
                  onRetry: selectedNetwork == null
                      ? null
                      : () => _loadDevices(selectedNetwork!.id),
                  onShowHelloWorld: widget.onShowHelloWorld,
                ),
              ),
              const SizedBox(height: 12),
              FButton(
                variant: FButtonVariant.outline,
                onPress: () => unawaited(widget.onLogout()),
                prefix: const Icon(Icons.logout_rounded, size: 18),
                child: const Text('退出登录'),
              ),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 248,
                child: Column(
                  children: [
                    _WorkspaceHero(
                      session: widget.session,
                      workspace: _workspace,
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _NetworkListCard(
                        networks: _networks,
                        selectedNetworkId: _selectedNetworkId,
                        isLoading: _isLoadingNetworks,
                        error: _networkError,
                        onRetry: _loadNetworks,
                        onSelect: _selectNetwork,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FButton(
                      variant: FButtonVariant.outline,
                      onPress: () => unawaited(widget.onLogout()),
                      prefix: const Icon(Icons.logout_rounded, size: 18),
                      child: const Text('退出登录'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _DevicePanelCard(
                  selectedNetwork: selectedNetwork,
                  devices: _devices,
                  isLoading: _isLoadingDevices,
                  error: _deviceError,
                  onRetry: selectedNetwork == null
                      ? null
                      : () => _loadDevices(selectedNetwork!.id),
                  onShowHelloWorld: widget.onShowHelloWorld,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WorkspaceHero extends StatelessWidget {
  const _WorkspaceHero({required this.session, required this.workspace});

  final AuthSession session;
  final ConsoleWorkspace? workspace;

  @override
  Widget build(BuildContext context) {
    final user = session.user;

    return _AppCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _AvatarLabel(name: user.effectiveName, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _StatusDot(color: _success),
                          SizedBox(width: 8),
                          Text(
                            '控制台已连接',
                            style: TextStyle(
                              color: _mutedForeground,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        user.effectiveName.isEmpty ? '用户' : user.effectiveName,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _DetailRow(
              label: '邮箱',
              value: user.email.isEmpty ? '未提供' : user.email,
            ),
            _DetailRow(label: '工作空间', value: workspace?.name ?? '未关联工作区'),
          ],
        ),
      ),
    );
  }
}

class _NetworkListCard extends StatelessWidget {
  const _NetworkListCard({
    required this.networks,
    required this.selectedNetworkId,
    required this.isLoading,
    required this.error,
    required this.onRetry,
    required this.onSelect,
  });

  final List<ConsoleNetwork> networks;
  final String? selectedNetworkId;
  final bool isLoading;
  final String? error;
  final Future<void> Function() onRetry;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return _AppCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _CardTitle(icon: Icons.hub_outlined, title: '网络'),
            const SizedBox(height: 10),
            Expanded(child: _buildContent(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (isLoading) {
      return const Center(child: FCircularProgress());
    }

    final errorMessage = error;
    if (errorMessage != null) {
      return _RetryMessage(message: errorMessage, onRetry: onRetry);
    }

    if (networks.isEmpty) {
      return const Center(child: Text('当前工作区暂无网络'));
    }

    return ListView.separated(
      itemCount: networks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final network = networks[index];
        final selected = network.id == selectedNetworkId;
        return _NetworkTile(
          network: network,
          selected: selected,
          onTap: () => onSelect(network.id),
        );
      },
    );
  }
}

class _NetworkTile extends StatelessWidget {
  const _NetworkTile({
    required this.network,
    required this.selected,
    required this.onTap,
  });

  final ConsoleNetwork network;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? _foreground : _appBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? _foreground : _border),
        ),
        child: Row(
          children: [
            _StatusDot(color: selected ? _brandCoral : _mutedForeground),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                network.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : _foreground,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DevicePanelCard extends StatelessWidget {
  const _DevicePanelCard({
    required this.selectedNetwork,
    required this.devices,
    required this.isLoading,
    required this.error,
    required this.onRetry,
    required this.onShowHelloWorld,
  });

  final ConsoleNetwork? selectedNetwork;
  final List<NetworkDevice> devices;
  final bool isLoading;
  final String? error;
  final Future<void> Function()? onRetry;
  final VoidCallback onShowHelloWorld;

  @override
  Widget build(BuildContext context) {
    final network = selectedNetwork;

    return _AppCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    network == null ? '请选择网络' : '网络: ${network.name}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  variant: FButtonVariant.outline,
                  onPress: onShowHelloWorld,
                  prefix: const Icon(Icons.bolt_rounded, size: 18),
                  child: const Text('弹出 Hello World'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _MetricTile(
                  label: '网络',
                  value: network == null ? '—' : '1',
                  color: _brandCoral,
                ),
                _MetricTile(
                  label: '设备',
                  value: devices.length.toString(),
                  color: _brandBlue,
                ),
                _MetricTile(
                  label: '在线',
                  value: devices
                      .where((device) => device.online)
                      .length
                      .toString(),
                  color: _success,
                ),
                const _MetricTile(label: '路由', value: '—', color: _brandPurple),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final network = selectedNetwork;
    if (network == null) {
      return const Center(child: Text('请选择左侧网络以查看设备情况'));
    }

    if (isLoading) {
      return const Center(child: FCircularProgress());
    }

    final errorMessage = error;
    final retry = onRetry;
    if (errorMessage != null) {
      return _RetryMessage(message: errorMessage, onRetry: retry);
    }

    if (devices.isEmpty) {
      return const Center(child: Text('该网络暂无设备'));
    }

    return ListView.separated(
      itemCount: devices.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _DeviceTile(device: devices[index]),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device});

  final NetworkDevice device;

  @override
  Widget build(BuildContext context) {
    final statusText = device.online ? '在线' : '离线';
    final statusColor = device.online ? _success : _mutedForeground;
    final ipv4 = device.ipv4;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _appBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          _StatusDot(color: statusColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  ipv4 == null || ipv4.isEmpty
                      ? 'ID: ${device.id}'
                      : 'IP: $ipv4  |  ID: ${device.id}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _mutedForeground, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _Pill(label: statusText, color: statusColor),
        ],
      ),
    );
  }
}

class _RetryMessage extends StatelessWidget {
  const _RetryMessage({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FButton(
              mainAxisSize: MainAxisSize.min,
              onPress: onRetry == null ? null : () => unawaited(onRetry!()),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({super.key, required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return _AuthShell(
      accentColor: Theme.of(context).colorScheme.error,
      eyebrow: '认证失败',
      title: '无法完成登录',
      description: message,
      action: FButton(
        mainAxisSize: MainAxisSize.min,
        onPress: () => unawaited(onRetry()),
        prefix: const Icon(Icons.refresh_rounded, size: 18),
        child: const Text('重新尝试登录'),
      ),
      detail: const _InfoStrip(
        icon: Icons.error_outline_rounded,
        text: '如果问题持续出现，请检查控制台地址、网络连接或授权状态。',
      ),
    );
  }
}

class _AvatarLabel extends StatelessWidget {
  const _AvatarLabel({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = name.trim().isEmpty
        ? 'U'
        : name.trim().characters.first.toUpperCase();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _foreground.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(size / 2),
        border: Border.all(color: _border),
      ),
      alignment: Alignment.center,
      child: Text(
        fallback,
        style: TextStyle(
          color: _foreground,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _foreground),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(color: _mutedForeground, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 108,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _cardBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusDot(color: color),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: _mutedForeground, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return FBadge(
      variant: FBadgeVariant.outline,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(color: color),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
=======
>>>>>>> f969a8e (Refactor auth and home UI into separate files)
