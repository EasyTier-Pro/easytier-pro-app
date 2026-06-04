import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

part 'console_auth_models.dart';
part 'auth_service_contract.dart';
part 'oauth_token_store.dart';
part 'console_auth_http_service.dart';

const String defaultConsoleBaseUrl = String.fromEnvironment(
  'EASYTIER_CONSOLE_URL',
  defaultValue: 'https://api.console.easytier.net',
);
