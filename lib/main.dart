import 'dart:async';
import 'dart:ui';

import 'package:forui/forui.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/auth/auth_gate.dart';
import 'src/auth/console_auth_service.dart';
import 'src/core/core_lifecycle_service.dart';
import 'src/desktop/tray_support.dart';
import 'src/logging/app_logger.dart';
import 'src/shared/app_motion.dart';

const Color _appBackground = Color(0xFFF8F9FB);
const Color _cardBackground = Color(0xFFFFFFFF);
const Color _foreground = Color(0xFF0A0A0A);
const Color _border = Color(0xFFE5E7EB);
const Color _brandCoral = Color(0xFFFF5530);
const String _appFontFamily = 'Inter';
const List<String> _appFontFamilyFallback = <String>[
  'Noto Sans SC',
  'PingFang SC',
  'Microsoft YaHei',
  'Arial Unicode MS',
];

final FThemeData _foruiThemeData = _createForuiThemeData();

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
  final coreLifecycleService = CoreLifecycleService(authService: authService);
  final traySupport = createTraySupport();

  await traySupport.initialize();
  AppLogger.instance.info('main', 'Application initialized');

  runApp(
    MyApp(
      authService: authService,
      traySupport: traySupport,
      coreLifecycleService: coreLifecycleService,
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    required this.authService,
    required this.traySupport,
    required this.coreLifecycleService,
  });

  final AuthService authService;
  final TraySupport traySupport;
  final CoreLifecycleService coreLifecycleService;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    widget.traySupport.setRepairAction(
      () => widget.coreLifecycleService.repair(),
    );
    widget.coreLifecycleService.status.addListener(_onCoreStatusChanged);
    unawaited(
      widget.traySupport.updateCoreStatus(
        widget.coreLifecycleService.status.value,
      ),
    );
  }

  @override
  void dispose() {
    widget.coreLifecycleService.status.removeListener(_onCoreStatusChanged);
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
      title: 'EasyTier Pro',
      scrollBehavior: const AppScrollBehavior(),
      builder: (context, child) => FTheme(
        data: _foruiThemeData,
        child: FToaster(child: child ?? const SizedBox.shrink()),
      ),
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
        coreLifecycleService: widget.coreLifecycleService,
      ),
    );
  }
}

final TextTheme _materialTextTheme = TextTheme(
  headlineMedium: _appTextStyle(
    const TextStyle(fontWeight: FontWeight.w800, height: 1.08),
  ),
  headlineSmall: _appTextStyle(
    const TextStyle(fontWeight: FontWeight.w800, height: 1.12),
  ),
  titleLarge: _appTextStyle(const TextStyle(fontWeight: FontWeight.w800)),
  titleMedium: _appTextStyle(const TextStyle(fontWeight: FontWeight.w700)),
  bodyMedium: _appTextStyle(const TextStyle(height: 1.5)),
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
  );

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
