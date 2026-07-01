import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/auth/auth_gate.dart';
import 'src/auth/console_auth_service.dart';
import 'src/core/core_lifecycle_service.dart';
import 'src/desktop/app_update_service.dart';
import 'src/desktop/tray_support.dart';
import 'src/desktop/window_behavior_preferences.dart';
import 'src/logging/app_logger.dart';
import 'src/shared/app_motion.dart';
import 'src/telemetry/app_client_reporter.dart';

const Color _appBackground = Color(0xFFF8F9FB);
const Color _cardBackground = Color(0xFFFFFFFF);
const Color _foreground = Color(0xFF0A0A0A);
const Color _border = Color(0xFFE5E7EB);
const Color _brandCoral = Color(0xFFFF5530);
const String _appFontFamily = 'Inter';
const String _deviceAuthReturnPath = '/device-complete';
const double _foruiTypographyScale = 0.96;
const List<String> _appFontFamilyFallback = <String>[
  'Noto Sans SC',
  'PingFang SC',
  'Microsoft YaHei',
  'Arial Unicode MS',
];

final FThemeData _foruiThemeData = _createForuiThemeData();

enum _TrayExitChoice { appOnly, appAndService }

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.instance.initialize();
  FlutterError.onError = (details) {
    AppLogger.instance.error(
      'flutter',
      details.exceptionAsString(),
      context: {'stack': details.stack?.toString() ?? ''},
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.instance.error(
      'platform',
      error.toString(),
      context: {'stack': stack.toString()},
    );
    return false;
  };

  final preferences = await SharedPreferences.getInstance();
  final authService = ConsoleAuthService(
    tokenStore: OAuthTokenStore(preferences),
  );
  final tokenConnectionProfileStore = TokenConnectionProfileStore(preferences);
  final appClientReporter = AppClientReporter(preferences: preferences);
  final coreLifecycleService = CoreLifecycleService(
    authService: authService,
    appClientReporter: appClientReporter,
  );
  final windowBehaviorPreferences = WindowBehaviorPreferences(preferences);
  final traySupport = createTraySupport(
    windowBehaviorPreferences: windowBehaviorPreferences,
  );
  final appUpdateService = AppUpdateService(
    onBeforeQuitForUpdate: () => quitForAppUpdate(
      coreLifecycleService: coreLifecycleService,
      traySupport: traySupport,
    ),
  );

  await traySupport.initialize();
  unawaited(appUpdateService.initialize());
  AppLogger.instance.info('main', 'Application initialized');

  runApp(
    MyApp(
      authService: authService,
      tokenConnectionProfileStore: tokenConnectionProfileStore,
      traySupport: traySupport,
      coreLifecycleService: coreLifecycleService,
      appUpdateService: appUpdateService,
      windowBehaviorPreferences: windowBehaviorPreferences,
    ),
  );
}

@visibleForTesting
Future<void> quitForAppUpdate({
  required CoreLifecycleService coreLifecycleService,
  required TraySupport traySupport,
}) async {
  await coreLifecycleService.stopRuntimeForUserExit();
  await traySupport.quitApp(reason: AppExitReason.update);
}

class MyApp extends StatefulWidget {
  MyApp({
    super.key,
    required this.authService,
    required this.traySupport,
    required this.coreLifecycleService,
    AppUpdateService? appUpdateService,
    TokenConnectionProfileStore? tokenConnectionProfileStore,
    this.windowBehaviorPreferences,
    this.androidMvpSingleActiveNetworkOverride,
  }) : appUpdateService = appUpdateService ?? AppUpdateService(),
       tokenConnectionProfileStore =
           tokenConnectionProfileStore ?? TokenConnectionProfileStore.memory();

  final AuthService authService;
  final TraySupport traySupport;
  final CoreLifecycleService coreLifecycleService;
  final AppUpdateService appUpdateService;
  final TokenConnectionProfileStore tokenConnectionProfileStore;
  final WindowBehaviorPreferences? windowBehaviorPreferences;
  final bool? androidMvpSingleActiveNetworkOverride;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final WindowBehaviorPreferences _windowBehaviorPreferences;
  bool _trayExitDialogVisible = false;
  bool _trayExitInProgress = false;

  @override
  void initState() {
    super.initState();
    _windowBehaviorPreferences =
        widget.windowBehaviorPreferences ?? WindowBehaviorPreferences.memory();
    _registerTrayExitAction(widget.traySupport);
    widget.coreLifecycleService.status.addListener(_onCoreStatusChanged);
    unawaited(
      widget.traySupport.updateCoreStatus(
        widget.coreLifecycleService.status.value,
      ),
    );
  }

  @override
  void didUpdateWidget(MyApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.traySupport != widget.traySupport) {
      oldWidget.traySupport.setExitAction(null);
      _registerTrayExitAction(widget.traySupport);
    }
  }

  @override
  void dispose() {
    widget.traySupport.setExitAction(null);
    widget.coreLifecycleService.status.removeListener(_onCoreStatusChanged);
    widget.appUpdateService.dispose();
    unawaited(widget.traySupport.dispose());
    super.dispose();
  }

  void _onCoreStatusChanged() {
    unawaited(
      widget.traySupport.updateCoreStatus(
        widget.coreLifecycleService.status.value,
      ),
    );
  }

  void _registerTrayExitAction(TraySupport traySupport) {
    traySupport.setExitAction(
      TrayMenuAction(
        label: '退出',
        enabled: true,
        onSelected: _handleTrayExitRequested,
      ),
    );
  }

  Future<void> _handleTrayExitRequested() async {
    if (_trayExitDialogVisible || _trayExitInProgress) {
      await widget.traySupport.showWindow();
      return;
    }

    _trayExitDialogVisible = true;
    try {
      await widget.traySupport.showWindow();
      if (!mounted) {
        return;
      }

      final context = _navigatorKey.currentContext;
      if (context == null || !context.mounted) {
        return;
      }
      final choice = await _showTrayExitDialog(context);
      if (!mounted || choice == null) {
        return;
      }

      _trayExitInProgress = true;
      try {
        if (choice == _TrayExitChoice.appOnly) {
          await widget.traySupport.quitApp();
          return;
        }

        try {
          await widget.coreLifecycleService.stopRuntimeForUserExit();
        } catch (error, stack) {
          AppLogger.instance.error(
            'tray',
            'Failed to stop runtime before tray exit',
            context: {'error': error.toString(), 'stack': stack.toString()},
          );
          if (!mounted) {
            return;
          }
          final toastContext = _navigatorKey.currentContext;
          if (toastContext != null && toastContext.mounted) {
            _showTrayExitFailureToast(toastContext, error);
          }
          return;
        }
        if (!mounted) {
          return;
        }
        await widget.traySupport.quitApp();
      } finally {
        _trayExitInProgress = false;
      }
    } finally {
      _trayExitDialogVisible = false;
    }
  }

  Future<_TrayExitChoice?> _showTrayExitDialog(BuildContext context) {
    return showFDialog<_TrayExitChoice>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext, _, animation) => ExcludeSemantics(
        child: FDialog.adaptive(
          animation: animation,
          title: const Text('退出 EasyTier Pro'),
          body: const Text('仅退出前台程序不会停止后台服务；退出后台服务会停止本机连接引擎，并可能取消开机自启。'),
          actions: [
            FButton(
              onPress: () =>
                  Navigator.of(dialogContext).pop(_TrayExitChoice.appOnly),
              child: const Text('仅退出前台程序'),
            ),
            FButton(
              variant: .destructive,
              onPress: () => Navigator.of(
                dialogContext,
              ).pop(_TrayExitChoice.appAndService),
              child: const Text('退出前台和后台服务'),
            ),
            FButton(
              variant: .outline,
              onPress: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }

  void _showTrayExitFailureToast(BuildContext context, Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    showRawFToast(
      context: context,
      variant: FToastVariant.destructive,
      alignment: defaultTargetPlatform == TargetPlatform.android
          ? FToastAlignment.topCenter
          : null,
      builder: (context, entry) => FToast(
        variant: FToastVariant.destructive,
        title: Text('后台服务停止失败：$message'),
      ),
    );
  }

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
      navigatorKey: _navigatorKey,
      title: 'EasyTier Pro',
      scrollBehavior: const AppScrollBehavior(),
      builder: (context, child) {
        final app = FTheme(
          data: _foruiThemeData,
          child: FToaster(child: child ?? const SizedBox.shrink()),
        );

        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
          return ExcludeSemantics(child: app);
        }

        return app;
      },
      onGenerateRoute: _onGenerateRoute,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: _appBackground,
        fontFamily: _appFontFamily,
        fontFamilyFallback: _appFontFamilyFallback,
        textTheme: _materialTextTheme,
        useMaterial3: true,
      ),
      home: AuthGate(
        authService: widget.authService,
        tokenConnectionProfileStore: widget.tokenConnectionProfileStore,
        coreLifecycleService: widget.coreLifecycleService,
        traySupport: widget.traySupport,
        appUpdateService: widget.appUpdateService,
        windowBehaviorPreferences: _windowBehaviorPreferences,
        androidMvpSingleActiveNetworkOverride:
            widget.androidMvpSingleActiveNetworkOverride,
      ),
    );
  }

  Route<void>? _onGenerateRoute(RouteSettings settings) {
    if (settings.name != _deviceAuthReturnPath) {
      return null;
    }
    AppLogger.instance.info(
      'auth.deeplink',
      'Consumed device authorization return route',
      context: {'route': settings.name ?? ''},
    );
    return PageRouteBuilder<void>(
      settings: settings,
      opaque: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) {
        return const _DeviceAuthReturnRoute();
      },
    );
  }
}

class _DeviceAuthReturnRoute extends StatefulWidget {
  const _DeviceAuthReturnRoute();

  @override
  State<_DeviceAuthReturnRoute> createState() => _DeviceAuthReturnRouteState();
}

class _DeviceAuthReturnRouteState extends State<_DeviceAuthReturnRoute> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final navigator = Navigator.maybeOf(context);
      if (navigator != null) {
        unawaited(navigator.maybePop());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

final TextTheme _materialTextTheme = TextTheme(
  headlineMedium: _appTextStyle(
    const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.12),
  ),
  headlineSmall: _appTextStyle(
    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.16),
  ),
  titleLarge: _appTextStyle(
    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.25),
  ),
  titleMedium: _appTextStyle(
    const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.35),
  ),
  titleSmall: _appTextStyle(
    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, height: 1.35),
  ),
  bodyLarge: _appTextStyle(const TextStyle(fontSize: 13.5, height: 1.45)),
  bodyMedium: _appTextStyle(const TextStyle(fontSize: 13, height: 1.45)),
  bodySmall: _appTextStyle(const TextStyle(fontSize: 11.5, height: 1.35)),
  labelLarge: _appTextStyle(
    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.35),
  ),
  labelMedium: _appTextStyle(
    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.3),
  ),
  labelSmall: _appTextStyle(
    const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, height: 1.25),
  ),
);

FThemeData _createForuiThemeData() {
  final colors = FThemes.neutral.light.desktop.colors;
  return FThemeData(
    colors: colors,
    touch: false,
    debugLabel: 'EasyTier Pro Light Desktop',
    typography: _foruiTypography(colors),
  );
}

FTypography _foruiTypography(FColors colors) {
  final base = FTypography.inherit(
    colors: colors,
    touch: false,
    fontFamily: _appFontFamily,
  ).scale(sizeScalar: _foruiTypographyScale);

  return base.copyWith(
    xs3: _appTextStyle(base.xs3),
    xs2: _appTextStyle(base.xs2),
    xs: _appTextStyle(base.xs),
    sm: _appTextStyle(base.sm),
    md: _appTextStyle(base.md),
    lg: _appTextStyle(base.lg),
    xl: _appTextStyle(base.xl),
    xl2: _appTextStyle(base.xl2),
    xl3: _appTextStyle(base.xl3),
    xl4: _appTextStyle(base.xl4),
    xl5: _appTextStyle(base.xl5),
    xl6: _appTextStyle(base.xl6),
    xl7: _appTextStyle(base.xl7),
    xl8: _appTextStyle(base.xl8),
  );
}

TextStyle _appTextStyle(TextStyle style) {
  return style.copyWith(
    fontFamily: _appFontFamily,
    fontFamilyFallback: _appFontFamilyFallback,
  );
}
