import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/auth/console_auth_service.dart';

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
    return MaterialApp(
      title: 'EasyTier Pro',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B7A75)),
        fontFamilyFallback: const [
          'PingFang SC',
          'Microsoft YaHei',
          'Noto Sans CJK SC',
          'Arial Unicode MS',
        ],
        useMaterial3: true,
      ),
      home: AuthGate(authService: authService),
    );
  }
}

enum AuthStage {
  checking,
  loginRequired,
  requestingCode,
  waitingForApproval,
  authenticated,
  error,
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.authService});

  final AuthService authService;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AuthStage _stage = AuthStage.checking;
  DeviceAuthInfo? _deviceAuthInfo;
  AuthSession? _session;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    _setStage(AuthStage.checking, statusMessage: '正在检查本地登录状态...');

    try {
      final session = await widget.authService.restoreSession();
      if (session != null) {
        _setSession(session);
        return;
      }

      _setStage(AuthStage.loginRequired);
    } catch (error) {
      _setError(error.toString());
    }
  }

  Future<void> _startLogin() async {
    _setStage(AuthStage.requestingCode, statusMessage: '正在向控制台申请设备登录验证码...');

    try {
      final info = await widget.authService.startDeviceAuth();
      if (!mounted) {
        return;
      }

      setState(() {
        _stage = AuthStage.waitingForApproval;
        _deviceAuthInfo = info;
        _statusMessage = '请在浏览器完成授权，应用会自动继续登录。';
      });

      await _openBrowser(info.verificationUriComplete);
      unawaited(_waitForApproval(info));
    } catch (error) {
      _setError(error.toString());
    }
  }

  Future<void> _waitForApproval(DeviceAuthInfo info) async {
    try {
      final session = await widget.authService.completeDeviceAuth(info);
      _setSession(session);
    } catch (error) {
      _setError(error.toString());
    }
  }

  Future<void> _openBrowser(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      setState(() {
        _statusMessage = '未能自动打开浏览器，请手动复制链接完成授权。';
      });
    }
  }

  Future<void> _logout() async {
    await widget.authService.logout();
    if (!mounted) {
      return;
    }

    setState(() {
      _session = null;
      _deviceAuthInfo = null;
      _stage = AuthStage.loginRequired;
    });
  }

  void _showHelloWorldDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('提示'),
          content: const Text('Hello world'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _setSession(AuthSession session) {
    if (!mounted) {
      return;
    }

    setState(() {
      _stage = AuthStage.authenticated;
      _session = session;
      _deviceAuthInfo = null;
      _statusMessage = null;
    });
  }

  void _setError(String message) {
    if (!mounted) {
      return;
    }

    setState(() {
      _stage = AuthStage.error;
      _statusMessage = message.replaceFirst('Exception: ', '');
    });
  }

  void _setStage(AuthStage stage, {String? statusMessage}) {
    if (!mounted) {
      return;
    }

    setState(() {
      _stage = stage;
      _statusMessage = statusMessage;
    });
  }

  @override
  Widget build(BuildContext context) {
    final unauthenticatedBody = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: switch (_stage) {
              AuthStage.checking || AuthStage.requestingCode => _LoadingView(
                key: ValueKey<AuthStage>(_stage),
                message: _statusMessage ?? '加载中...',
              ),
              AuthStage.loginRequired => _LoginRequiredView(
                key: const ValueKey<String>('login-required'),
                onLogin: _startLogin,
              ),
              AuthStage.waitingForApproval => _DeviceAuthView(
                key: const ValueKey<String>('device-auth'),
                statusMessage: _statusMessage,
                onOpenBrowser: _deviceAuthInfo == null
                    ? null
                    : () => _openBrowser(
                        _deviceAuthInfo!.verificationUriComplete,
                      ),
              ),
              AuthStage.authenticated => const SizedBox.shrink(),
              AuthStage.error => _ErrorView(
                key: const ValueKey<String>('auth-error'),
                message: _statusMessage ?? '登录失败',
                onRetry: () async {
                  _setStage(AuthStage.loginRequired);
                },
              ),
            },
          ),
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Text('EasyTier Pro'),
      ),
      body: _stage == AuthStage.authenticated
          ? _WorkspaceHomeView(
              session: _session!,
              authService: widget.authService,
              onLogout: _logout,
              onShowHelloWorld: _showHelloWorldDialog,
            )
          : unauthenticatedBody,
    );
  }
}

class _LoginRequiredView extends StatelessWidget {
  const _LoginRequiredView({super.key, required this.onLogin});

  final Future<void> Function() onLogin;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('请先登录控制台', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onLogin,
              child: const Text('登录 EasyTier Pro'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _DeviceAuthView extends StatelessWidget {
  const _DeviceAuthView({
    super.key,
    required this.statusMessage,
    required this.onOpenBrowser,
  });

  final String? statusMessage;
  final VoidCallback? onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('请完成设备授权登录', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(statusMessage ?? '请在浏览器中完成授权，授权完成后会自动返回应用。'),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton(
                  onPressed: onOpenBrowser,
                  child: const Text('重新打开浏览器'),
                ),
              ],
            ),
          ],
        ),
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
    final workspaceName = _workspace?.name ?? '未关联工作区';

    return Row(
      children: [
        SizedBox(
          width: 280,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.hub_outlined),
                      const SizedBox(width: 8),
                      Text(
                        'EasyTier Pro',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      workspaceName,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                Expanded(child: _buildNetworkList(context)),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: widget.onLogout,
                      child: const Text('退出登录'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        selectedNetwork == null
                            ? '请选择网络'
                            : '网络: ${selectedNetwork.name}',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    OutlinedButton(
                      onPressed: widget.onShowHelloWorld,
                      child: const Text('弹出 Hello World'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(child: _buildDevicePanel(context, selectedNetwork)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkList(BuildContext context) {
    if (_isLoadingNetworks) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_networkError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_networkError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _loadNetworks, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_networks.isEmpty) {
      return const Center(child: Text('当前工作区暂无网络'));
    }

    return ListView.builder(
      itemCount: _networks.length,
      itemBuilder: (context, index) {
        final network = _networks[index];
        final selected = network.id == _selectedNetworkId;
        return ListTile(
          leading: const Icon(Icons.device_hub_outlined),
          title: Text(network.name),
          selected: selected,
          onTap: () => _selectNetwork(network.id),
        );
      },
    );
  }

  Widget _buildDevicePanel(
    BuildContext context,
    ConsoleNetwork? selectedNetwork,
  ) {
    if (selectedNetwork == null) {
      return const Center(child: Text('请选择左侧网络以查看设备情况'));
    }

    if (_isLoadingDevices) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_deviceError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_deviceError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _loadDevices(selectedNetwork.id),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_devices.isEmpty) {
      return const Center(child: Text('该网络暂无设备'));
    }

    return Card(
      child: ListView.separated(
        itemCount: _devices.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final device = _devices[index];
          final statusText = device.online ? '在线' : '离线';
          final statusColor = device.online ? Colors.green : Colors.grey;

          return ListTile(
            leading: CircleAvatar(radius: 6, backgroundColor: statusColor),
            title: Text(device.name),
            subtitle: Text(
              device.ipv4 == null || device.ipv4!.isEmpty
                  ? 'ID: ${device.id}'
                  : 'IP: ${device.ipv4}  |  ID: ${device.id}',
            ),
            trailing: Text(statusText),
          );
        },
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('登录失败', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(message),
            const SizedBox(height: 24),
            FilledButton(onPressed: onRetry, child: const Text('重新尝试登录')),
          ],
        ),
      ),
    );
  }
}
