import 'dart:async';

import 'package:forui/forui.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/auth/auth_gate.dart';
import 'src/auth/console_auth_service.dart';
import 'src/desktop/tray_support.dart';

const Color _appBackground = Color(0xFFF8F9FB);
const Color _cardBackground = Color(0xFFFFFFFF);
const Color _foreground = Color(0xFF0A0A0A);
const Color _border = Color(0xFFE5E7EB);
const Color _brandCoral = Color(0xFFFF5530);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final authService = ConsoleAuthService(
    tokenStore: OAuthTokenStore(preferences),
  );
  final traySupport = createTraySupport();

  await traySupport.initialize();

  runApp(MyApp(authService: authService, traySupport: traySupport));
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    required this.authService,
    required this.traySupport,
  });

  final AuthService authService;
  final TraySupport traySupport;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void dispose() {
    unawaited(widget.traySupport.dispose());
    super.dispose();
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
      builder: (context, child) => FTheme(
        data: FThemes.neutral.light.desktop,
        child: child ?? const SizedBox.shrink(),
      ),
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: _appBackground,
        fontFamily: 'Inter',
        fontFamilyFallback: const [
          'Noto Sans SC',
          'PingFang SC',
          'Microsoft YaHei',
          'Arial Unicode MS',
        ],
        appBarTheme: const AppBarTheme(
          backgroundColor: _cardBackground,
          foregroundColor: _foreground,
          elevation: 0,
          centerTitle: false,
          surfaceTintColor: Colors.transparent,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _foreground,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 38),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _foreground,
            minimumSize: const Size(0, 38),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            side: const BorderSide(color: _border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: _foreground),
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(fontWeight: FontWeight.w800, height: 1.08),
          headlineSmall: TextStyle(fontWeight: FontWeight.w800, height: 1.12),
          titleLarge: TextStyle(fontWeight: FontWeight.w800),
          titleMedium: TextStyle(fontWeight: FontWeight.w700),
          bodyMedium: TextStyle(height: 1.5),
        ),
        useMaterial3: true,
      ),
      home: AuthGate(authService: widget.authService),
    );
  }
}
