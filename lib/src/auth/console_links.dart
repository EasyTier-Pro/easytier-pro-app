import 'console_auth_service.dart';

const _productionApiConsoleHost = 'api.console.easytier.net';
const _productionWebConsoleHost = 'console.easytier.net';

const _consoleNetworksFragment = '/networks';
const _consoleEnrollmentKeysFragment = '/devices?tab=keys';

Uri consoleHomeUri() => consoleWebUri();

Uri consoleNetworksUri() => consoleWebUri(fragment: _consoleNetworksFragment);

Uri consoleEnrollmentKeysUri() =>
    consoleWebUri(fragment: _consoleEnrollmentKeysFragment);

Uri consoleWebUri({String? fragment}) {
  final base = Uri.tryParse(defaultConsoleBaseUrl.trim());
  if (base == null || base.scheme.trim().isEmpty || base.host.trim().isEmpty) {
    return Uri.https(
      _productionWebConsoleHost,
      '/',
    ).replace(fragment: fragment);
  }

  final host = base.host == _productionApiConsoleHost
      ? _productionWebConsoleHost
      : base.host;
  return base.replace(host: host, path: '/', query: null, fragment: fragment);
}
