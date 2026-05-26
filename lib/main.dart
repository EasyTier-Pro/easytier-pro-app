import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        useMaterial3: true,
      ),
      home: AuthGate(authService: authService),
    );
  }
}

enum AuthStage {
  checking,
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

      await _beginDeviceAuth();
    } catch (error) {
      _setError(error.toString());
    }
  }

  Future<void> _beginDeviceAuth() async {
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

      unawaited(_openBrowser(info.verificationUriComplete));
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

  Future<void> _copyText(String value, String successMessage) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(successMessage)));
  }

  Future<void> _logout() async {
    await widget.authService.logout();
    if (!mounted) {
      return;
    }

    setState(() {
      _session = null;
      _deviceAuthInfo = null;
    });
    await _beginDeviceAuth();
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
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Text('EasyTier Pro'),
      ),
      body: Center(
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
                AuthStage.waitingForApproval => _DeviceAuthView(
                  key: const ValueKey<String>('device-auth'),
                  info: _deviceAuthInfo!,
                  statusMessage: _statusMessage,
                  onOpenBrowser: () =>
                      _openBrowser(_deviceAuthInfo!.verificationUriComplete),
                  onCopyCode: () =>
                      _copyText(_deviceAuthInfo!.userCode, '验证码已复制到剪贴板'),
                  onCopyUrl: () => _copyText(
                    _deviceAuthInfo!.verificationUriComplete,
                    '登录链接已复制到剪贴板',
                  ),
                ),
                AuthStage.authenticated => _LoggedInView(
                  key: const ValueKey<String>('logged-in'),
                  session: _session!,
                  onLogout: _logout,
                  onShowHelloWorld: _showHelloWorldDialog,
                ),
                AuthStage.error => _ErrorView(
                  key: const ValueKey<String>('auth-error'),
                  message: _statusMessage ?? '登录失败',
                  onRetry: _beginDeviceAuth,
                ),
              },
            ),
          ),
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
    required this.info,
    required this.statusMessage,
    required this.onOpenBrowser,
    required this.onCopyCode,
    required this.onCopyUrl,
  });

  final DeviceAuthInfo info;
  final String? statusMessage;
  final VoidCallback onOpenBrowser;
  final VoidCallback onCopyCode;
  final VoidCallback onCopyUrl;

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
            Text(statusMessage ?? '请在浏览器中完成授权。'),
            const SizedBox(height: 24),
            SelectableText('登录链接：${info.verificationUriComplete}'),
            const SizedBox(height: 12),
            SelectableText(
              '验证码：${info.userCode}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text('验证码将在 ${info.expiresIn} 秒后过期。'),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton(
                  onPressed: onOpenBrowser,
                  child: const Text('打开浏览器'),
                ),
                OutlinedButton(
                  onPressed: onCopyUrl,
                  child: const Text('复制登录链接'),
                ),
                OutlinedButton(
                  onPressed: onCopyCode,
                  child: const Text('复制验证码'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LoggedInView extends StatelessWidget {
  const _LoggedInView({
    super.key,
    required this.session,
    required this.onLogout,
    required this.onShowHelloWorld,
  });

  final AuthSession session;
  final VoidCallback onLogout;
  final VoidCallback onShowHelloWorld;

  @override
  Widget build(BuildContext context) {
    final user = session.user;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已登录控制台', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            Text('用户：${user.effectiveName}'),
            Text('邮箱：${user.email.isEmpty ? '未提供' : user.email}'),
            Text(
              '工作空间：${user.tenantNames.isEmpty ? '未读取到工作空间' : user.tenantNames.join('、')}',
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton(
                  onPressed: onShowHelloWorld,
                  child: const Text('弹出 Hello World'),
                ),
                OutlinedButton(onPressed: onLogout, child: const Text('退出登录')),
              ],
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
