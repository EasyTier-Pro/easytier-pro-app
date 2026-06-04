import 'dart:async';

import 'package:forui/forui.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/core_lifecycle_service.dart';
import '../logging/app_logger.dart';
import '../home/workspace_home_view.dart';
import '../shared/copyable_text.dart';
import 'console_auth_service.dart';

enum AuthStage {
  checking,
  loginRequired,
  requestingCode,
  waitingForApproval,
  authenticated,
  error,
}

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authService,
    required this.coreLifecycleService,
  });

  final AuthService authService;
  final CoreLifecycleService coreLifecycleService;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AuthStage _stage = AuthStage.checking;
  DeviceAuthInfo? _deviceAuthInfo;
  AuthSession? _session;
  String? _statusMessage;
  final AppLogger _logger = AppLogger.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    _logger.info('auth.gate', 'Bootstrapping auth gate');
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
    _logger.info('auth.gate', 'Starting interactive login');
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
      _logger.error(
        'auth.gate',
        'Start login failed',
        context: {'error': error.toString()},
      );
      _setError(error.toString());
    }
  }

  Future<void> _waitForApproval(DeviceAuthInfo info) async {
    try {
      final session = await widget.authService.completeDeviceAuth(info);
      _setSession(session);
    } catch (error) {
      _logger.error(
        'auth.gate',
        'Authorization completion failed',
        context: {'error': error.toString()},
      );
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
    _logger.info('auth.gate', 'Logout requested from UI');
    await widget.coreLifecycleService.onLogout();
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

  void _setSession(AuthSession session) {
    if (!mounted) {
      return;
    }

    _logger.info(
      'auth.gate',
      'Session established',
      context: {'workspace_count': session.user.workspaces.length},
    );
    unawaited(widget.coreLifecycleService.bindSession(session));

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

    _logger.error(
      'auth.gate',
      'Stage switched to error',
      context: {'message': message},
    );
    setState(() {
      _stage = AuthStage.error;
      _statusMessage = message.replaceFirst('Exception: ', '');
    });
  }

  void _setStage(AuthStage stage, {String? statusMessage}) {
    if (!mounted) {
      return;
    }

    _logger.debug(
      'auth.gate',
      'Stage updated',
      context: {'stage': stage.name, 'status': statusMessage ?? ''},
    );
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
                deviceAuthInfo: _deviceAuthInfo,
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

    if (_stage == AuthStage.authenticated) {
      return WorkspaceHomeView(
        session: _session!,
        authService: widget.authService,
        coreLifecycleService: widget.coreLifecycleService,
        onLogout: _logout,
      );
    }

    return FScaffold(
      header: const FHeader(title: Text('EasyTier Pro')),
      child: unauthenticatedBody,
    );
  }
}

class _LoginRequiredView extends StatelessWidget {
  const _LoginRequiredView({super.key, required this.onLogin});

  final Future<void> Function() onLogin;

  @override
  Widget build(BuildContext context) {
    return FCard(
      title: Text('请先登录控制台', style: Theme.of(context).textTheme.headlineSmall),
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('使用控制台账号授权此设备加入你的零信任网络。'),
            const SizedBox(height: 20),
            FButton(
              onPress: () => unawaited(onLogin()),
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
    return FCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FCircularProgress(),
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
    required this.deviceAuthInfo,
    required this.statusMessage,
    required this.onOpenBrowser,
  });

  final DeviceAuthInfo? deviceAuthInfo;
  final String? statusMessage;
  final VoidCallback? onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    return FCard(
      title: Text(
        '请完成设备授权登录',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(statusMessage ?? '请在浏览器中完成授权，授权完成后会自动返回应用。'),
            if (deviceAuthInfo != null) ...[
              const SizedBox(height: 16),
              _AuthCopyRow(
                label: '用户代码',
                value: deviceAuthInfo!.userCode,
                monospace: true,
              ),
              const SizedBox(height: 10),
              _AuthCopyRow(
                label: '授权链接',
                value: deviceAuthInfo!.verificationUriComplete,
                monospace: true,
              ),
            ],
            const SizedBox(height: 24),
            FButton(onPress: onOpenBrowser, child: const Text('重新打开浏览器')),
          ],
        ),
      ),
    );
  }
}

class _AuthCopyRow extends StatelessWidget {
  const _AuthCopyRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: const Color(0xFF334155),
      fontFamily: monospace ? 'monospace' : null,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(value, style: textStyle)),
          const SizedBox(width: 4),
          AppCopyButton(value: value, label: label),
        ],
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
    return FCard(
      title: Text('登录失败', style: Theme.of(context).textTheme.headlineSmall),
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(message)),
                const SizedBox(width: 8),
                AppCopyButton(value: message, label: '登录错误'),
              ],
            ),
            const SizedBox(height: 24),
            FButton(
              onPress: () => unawaited(onRetry()),
              child: const Text('重新尝试登录'),
            ),
          ],
        ),
      ),
    );
  }
}
