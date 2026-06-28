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

String defaultConfigServerUrlForConsoleBaseUrl(String consoleBaseUrl) {
  final uri = Uri.tryParse(consoleBaseUrl.trim());
  final host = uri?.host.trim() ?? '';
  if (host.isEmpty || host.endsWith('console.easytier.net')) {
    return 'tcp://api.console.easytier.net:22020';
  }
  return 'tcp://$host:22020';
}
