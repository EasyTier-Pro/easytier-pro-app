import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

part 'console_auth_models.dart';
part 'auth_service_contract.dart';
part 'oauth_token_store.dart';
part 'token_connection_profile_store.dart';
part 'console_auth_http_service.dart';

const String defaultConsoleBaseUrl = String.fromEnvironment(
  'EASYTIER_CONSOLE_URL',
  defaultValue: 'https://api.console.easytier.net',
);

const String _productionWebConfigServerUrl =
    'tcp://et-web.console.easytier.net:22020';
const String _legacyProductionConfigServerUrl =
    'tcp://api.console.easytier.net:22020';

String defaultConfigServerUrlForConsoleBaseUrl(String consoleBaseUrl) {
  final uri = Uri.tryParse(consoleBaseUrl.trim());
  final host = uri?.host.trim() ?? '';
  if (host.isEmpty || host.endsWith('console.easytier.net')) {
    return _productionWebConfigServerUrl;
  }
  return 'tcp://$host:22020';
}

bool isDefaultConfigServerUrlForConsoleBaseUrl(
  String configServer,
  String consoleBaseUrl,
) {
  final normalized = _normalizeConfigServerForComparison(configServer);
  if (normalized.isEmpty) {
    return true;
  }

  final currentDefault = _normalizeConfigServerForComparison(
    defaultConfigServerUrlForConsoleBaseUrl(consoleBaseUrl),
  );
  if (normalized == currentDefault) {
    return true;
  }

  final uri = Uri.tryParse(consoleBaseUrl.trim());
  final host = uri?.host.trim() ?? '';
  if (host.isEmpty || host.endsWith('console.easytier.net')) {
    return normalized ==
        _normalizeConfigServerForComparison(_legacyProductionConfigServerUrl);
  }
  return false;
}

String _normalizeConfigServerForComparison(String value) {
  return value.trim().replaceFirst(RegExp(r'/+$'), '');
}
