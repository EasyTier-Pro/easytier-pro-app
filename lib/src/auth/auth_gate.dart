import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/core_lifecycle_service.dart';
import '../desktop/tray_support.dart';
import '../logging/app_logger.dart';
import '../home/workspace_home_view.dart';
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
    required this.traySupport,
    this.androidMvpSingleActiveNetworkOverride,
  });

  final AuthService authService;
  final CoreLifecycleService coreLifecycleService;
  final TraySupport traySupport;
  final bool? androidMvpSingleActiveNetworkOverride;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  AuthStage _stage = AuthStage.checking;
  DeviceAuthInfo? _deviceAuthInfo;
  DeviceAuthInfo? _pendingApprovalInfo;
  AuthSession? _session;
  String? _statusMessage;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  bool _approvalWaitInFlight = false;
  bool _waitForBrowserReturn = false;
  int _approvalGeneration = 0;
  final AppLogger _logger = AppLogger.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _logger.debug(
      'auth.gate',
      'App lifecycle changed',
      context: {'state': state.name},
    );
    if (state == AppLifecycleState.resumed) {
      _startApprovalPollingIfReady();
    }
  }

  Future<void> _bootstrap() async {
    _logger.info('auth.gate', 'Bootstrapping auth gate');
    _setStage(AuthStage.checking, statusMessage: '正在检查本地登录状态…');

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
    _setStage(AuthStage.requestingCode, statusMessage: '正在向控制台申请设备登录验证码…');

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

      final generation = ++_approvalGeneration;
      setState(() {
        _pendingApprovalInfo = info;
        _waitForBrowserReturn = _shouldWaitForBrowserReturn;
        _statusMessage = _waitForBrowserReturn
            ? '请在浏览器完成授权，完成后返回 EasyTier Pro 继续登录。'
            : '请在浏览器完成授权，应用会自动继续登录。';
      });

      final opened = await _openBrowser(info.verificationUriComplete);
      if (!opened) {
        _waitForBrowserReturn = false;
        _startApprovalPollingIfReady(generation: generation);
        return;
      }
      if (!_waitForBrowserReturn) {
        _startApprovalPollingIfReady(generation: generation);
      } else {
        _logger.info(
          'auth.gate',
          'Deferring device authorization polling until app resumes',
        );
      }
    } catch (error) {
      _logger.error(
        'auth.gate',
        'Start login failed',
        context: {'error': error.toString()},
      );
      _setError(error.toString());
    }
  }

  Future<void> _waitForApproval(DeviceAuthInfo info, int generation) async {
    try {
      final session = await widget.authService.completeDeviceAuth(info);
      if (generation != _approvalGeneration) {
        return;
      }
      _setSession(session);
    } catch (error) {
      if (generation != _approvalGeneration) {
        return;
      }
      _logger.error(
        'auth.gate',
        'Authorization completion failed',
        context: {'error': error.toString()},
      );
      _setError(error.toString());
    } finally {
      if (generation == _approvalGeneration) {
        _approvalWaitInFlight = false;
      }
    }
  }

  Future<bool> _openBrowser(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      setState(() {
        _statusMessage = '未能自动打开浏览器，请手动复制链接完成授权。';
      });
    }
    return opened;
  }

  void _startApprovalPollingIfReady({int? generation}) {
    final info = _pendingApprovalInfo;
    if (info == null ||
        _stage != AuthStage.waitingForApproval ||
        _approvalWaitInFlight) {
      return;
    }
    if (_waitForBrowserReturn && _lifecycleState != AppLifecycleState.resumed) {
      return;
    }

    final activeGeneration = generation ?? _approvalGeneration;
    _approvalWaitInFlight = true;
    _waitForBrowserReturn = false;
    _logger.info(
      'auth.gate',
      'Starting device authorization polling',
      context: {'generation': activeGeneration},
    );
    unawaited(_waitForApproval(info, activeGeneration));
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
      _pendingApprovalInfo = null;
      _approvalWaitInFlight = false;
      _waitForBrowserReturn = false;
      _approvalGeneration++;
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
      _pendingApprovalInfo = null;
      _approvalWaitInFlight = false;
      _waitForBrowserReturn = false;
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
      _pendingApprovalInfo = null;
      _approvalWaitInFlight = false;
      _waitForBrowserReturn = false;
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

  bool get _shouldWaitForBrowserReturn {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  @override
  Widget build(BuildContext context) {
    if (_stage == AuthStage.authenticated) {
      return WorkspaceHomeView(
        session: _session!,
        authService: widget.authService,
        coreLifecycleService: widget.coreLifecycleService,
        traySupport: widget.traySupport,
        onLogout: _logout,
        androidMvpSingleActiveNetworkOverride:
            widget.androidMvpSingleActiveNetworkOverride,
      );
    }

    final content = _AuthPageShell(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: switch (_stage) {
          AuthStage.checking || AuthStage.requestingCode => _LoadingView(
            key: ValueKey<AuthStage>(_stage),
            message: _statusMessage ?? '加载中…',
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
          AuthStage.error => _ErrorView(
            key: const ValueKey<String>('auth-error'),
            message: _statusMessage ?? '登录失败',
            onRetry: () async => _setStage(AuthStage.loginRequired),
          ),
          AuthStage.authenticated => const SizedBox.shrink(),
        },
      ),
    );

    return FScaffold(
      child: content,
    );
  }
}

class _AuthPageShell extends StatelessWidget {
  const _AuthPageShell({required this.child});

  final Widget child;

  static const double _wideBreakpoint = 800;
  static const double _maxContentWidth = 420;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _wideBreakpoint;
        if (isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Expanded(
                flex: 5,
                child: _BrandPanel(),
              ),
              Expanded(
                flex: 5,
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: _maxContentWidth,
                            ),
                            child: child,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const _BrandPanel(compact: true),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: _maxContentWidth,
                    ),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final logoSize = compact ? 80.0 : 120.0;
    final titleStyle = compact
        ? theme.textTheme.headlineSmall
        : theme.textTheme.headlineMedium;

    return Semantics(
      container: true,
      label: 'EasyTier Pro 品牌区',
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 32,
            vertical: compact ? 24 : 48,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/easytier.png',
                width: logoSize,
                height: logoSize,
                semanticLabel: 'EasyTier Pro Logo',
              ),
              SizedBox(height: compact ? 16 : 24),
              Text(
                'EasyTier Pro',
                style: titleStyle?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '安全、简单的零信任组网',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
              SizedBox(height: compact ? 20 : 32),
              _BrandFooterLinks(compact: compact),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandFooterLinks extends StatelessWidget {
  const _BrandFooterLinks({this.compact = false});

  final bool compact;

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _link(BuildContext context, {required String label, required String url}) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => unawaited(_openUrl(url)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _link(context, label: '官网', url: 'https://easytier.cn'),
          const Text(' · '),
          _link(context, label: '控制台', url: 'https://console.easytier.net'),
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
    final theme = Theme.of(context);

    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '登录控制台',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '即刻加入你的私有零信任网络。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 24),
            FButton(
              onPress: () => unawaited(onLogin()),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.login, size: 18),
                  SizedBox(width: 8),
                  Text('开始登录'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '登录即表示你同意将本设备注册到所选工作区。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
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
    final theme = Theme.of(context);

    return FCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FCircularProgress(),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceAuthView extends StatefulWidget {
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
  State<_DeviceAuthView> createState() => _DeviceAuthViewState();
}

class _DeviceAuthViewState extends State<_DeviceAuthView> {
  late final DateTime _expiresAt;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _expiresAt = DateTime.now().add(
      Duration(seconds: widget.deviceAuthInfo?.expiresIn ?? 600),
    );
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _remainingText {
    final remaining = _expiresAt.difference(DateTime.now());
    if (remaining.isNegative) {
      return '已过期';
    }
    final minutes = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  bool get _isExpired {
    return _expiresAt.isBefore(DateTime.now());
  }

  Future<void> _copyCode(BuildContext context, String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) {
      return;
    }
    _showToast(context, '用户代码已复制');
  }

  Future<void> _copyUrl(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) {
      return;
    }
    _showToast(context, '授权链接已复制');
  }

  void _showToast(BuildContext context, String message) {
    showRawFToast(
      context: context,
      variant: FToastVariant.primary,
      duration: const Duration(seconds: 2),
      builder: (context, entry) => FToast(title: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.deviceAuthInfo;
    final status = widget.statusMessage ?? '在浏览器页面中输入用户代码，完成授权后应用会自动继续。';

    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.browser_updated_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '请在浏览器中完成授权',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              status,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            if (info != null) ...[
              const SizedBox(height: 24),
              _AuthCodeBlock(
                label: '用户代码',
                value: info.userCode,
                onCopy: (value) => unawaited(_copyCode(context, value)),
              ),
              const SizedBox(height: 16),
              _AuthCodeBlock(
                label: '授权链接',
                value: info.verificationUriComplete,
                onCopy: (value) => unawaited(_copyUrl(context, value)),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: 16,
                    color: _isExpired
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isExpired ? '授权码已过期' : '授权码有效期：$_remainingText',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _isExpired
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            FButton(
              onPress: widget.onOpenBrowser,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_in_new, size: 18),
                  SizedBox(width: 8),
                  Text('打开授权页面'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthCodeBlock extends StatelessWidget {
  const _AuthCodeBlock({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontFamilyFallback: const <String>[
                      'Noto Sans SC',
                      'PingFang SC',
                      'Microsoft YaHei',
                    ],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FTooltip(
                tipBuilder: (context, controller) => Text('复制$label'),
                child: FButton(
                  variant: FButtonVariant.ghost,
                  onPress: () => onCopy(value),
                  child: const Icon(Icons.copy, size: 18),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({super.key, required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '登录失败',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                FButton(
                  onPress: () => unawaited(onRetry()),
                  child: const Text('重新尝试登录'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
