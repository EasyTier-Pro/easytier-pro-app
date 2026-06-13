import 'dart:convert';
import 'dart:io';

const _sparkleNamespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

void main(List<String> args) {
  if (args.isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }

  final command = args.first;
  final parsed = _ParsedArgs.parse(args.skip(1).toList());

  try {
    switch (command) {
      case 'metadata':
        _writeMetadata(parsed);
        break;
      case 'appcast':
        _writeAppcast(parsed);
        break;
      default:
        throw ArgumentError('Unknown command: $command');
    }
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

void _writeMetadata(_ParsedArgs args) {
  final platform = args.requiredOption('platform');
  if (platform != 'macos' && platform != 'windows') {
    throw ArgumentError('platform must be macos or windows');
  }

  final artifact = File(args.requiredOption('artifact'));
  if (!artifact.existsSync()) {
    throw ArgumentError('Artifact was not found: ${artifact.path}');
  }

  final signatureOutput =
      args.option('signature') ??
      File(args.requiredOption('signature-file')).readAsStringSync();
  final signatureAttributes = _parseXmlAttributes(signatureOutput);
  final signatureAttribute = platform == 'macos'
      ? 'sparkle:edSignature'
      : 'sparkle:dsaSignature';
  final signature = signatureAttributes[signatureAttribute];
  if (signature == null || signature.isEmpty) {
    throw ArgumentError('Signature output did not contain $signatureAttribute');
  }

  final length = artifact.lengthSync();
  final signedLength = int.tryParse(signatureAttributes['length'] ?? '');
  if (signedLength != null && signedLength != 0 && signedLength != length) {
    throw ArgumentError(
      'Signature length $signedLength does not match artifact length $length',
    );
  }

  final appVersion = _parseAppVersion(
    args.option('app-version') ?? _readPubspecVersion(),
  );
  final arch = args.option('arch') ?? '';
  final platformName = platform == 'macos' ? 'macOS' : 'Windows';
  final archSuffix = arch.isEmpty ? '' : ' $arch';
  final title =
      args.option('title') ??
      'Version ${appVersion.shortVersion} for $platformName$archSuffix';

  final metadata = <String, Object?>{
    'schema': 1,
    'platform': platform,
    'arch': arch,
    'fileName': _basename(artifact.path),
    'length': length,
    'signatureAttribute': signatureAttribute,
    'signature': signature,
    'sparkleVersion':
        args.option('sparkle-version') ??
        (platform == 'macos' ? appVersion.buildNumber : appVersion.raw),
    'shortVersion': args.option('short-version') ?? appVersion.shortVersion,
    'title': title,
    'pubDate':
        args.option('pub-date') ?? HttpDate.format(DateTime.now().toUtc()),
  };

  final output = File(args.requiredOption('output'));
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(metadata),
  );
  stdout.writeln('Appcast metadata written: ${output.path}');
}

void _writeAppcast(_ParsedArgs args) {
  final metadataFiles = args.rest.map(File.new).toList();
  if (metadataFiles.isEmpty) {
    throw ArgumentError('At least one metadata JSON file is required');
  }

  final items = metadataFiles.map(_readMetadata).toList()
    ..sort(_compareMetadata);
  final baseUrl = args.requiredOption('base-url');
  final releaseNotesUrl = args.option('release-notes-url');
  final channelTitle = args.option('channel-title') ?? 'EasyTier Pro';
  final channelLink = args.option('channel-link') ?? 'https://easytier.net/';
  final channelDescription =
      args.option('channel-description') ?? 'EasyTier Pro desktop releases';

  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<rss version="2.0" xmlns:sparkle="$_sparkleNamespace">')
    ..writeln('  <channel>')
    ..writeln('    <title>${_xmlText(channelTitle)}</title>')
    ..writeln('    <link>${_xmlText(channelLink)}</link>')
    ..writeln('    <description>${_xmlText(channelDescription)}</description>')
    ..writeln('    <language>zh-CN</language>');

  for (final item in items) {
    final downloadUrl = _joinUrl(baseUrl, item.string('fileName'));
    buffer
      ..writeln('    <item>')
      ..writeln('      <title>${_xmlText(item.string('title'))}</title>')
      ..writeln('      <link>${_xmlText(channelLink)}</link>')
      ..writeln(
        '      <sparkle:version>${_xmlText(item.string('sparkleVersion'))}</sparkle:version>',
      )
      ..writeln(
        '      <sparkle:shortVersionString>${_xmlText(item.string('shortVersion'))}</sparkle:shortVersionString>',
      );

    if (item.string('platform') == 'macos' && item.string('arch') == 'arm64') {
      buffer.writeln(
        '      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>',
      );
    }

    if (releaseNotesUrl != null && releaseNotesUrl.isNotEmpty) {
      buffer.writeln(
        '      <sparkle:releaseNotesLink>${_xmlText(releaseNotesUrl)}</sparkle:releaseNotesLink>',
      );
    }

    buffer
      ..writeln('      <pubDate>${_xmlText(item.string('pubDate'))}</pubDate>')
      ..writeln('      <enclosure')
      ..writeln('        url="${_xmlAttribute(downloadUrl)}"')
      ..writeln(
        '        ${item.string('signatureAttribute')}="${_xmlAttribute(item.string('signature'))}"',
      )
      ..writeln(
        '        sparkle:os="${_xmlAttribute(item.string('platform'))}"',
      )
      ..writeln('        length="${item.intValue('length')}"')
      ..writeln('        type="application/octet-stream" />')
      ..writeln('    </item>');
  }

  buffer
    ..writeln('  </channel>')
    ..writeln('</rss>');

  final output = File(args.requiredOption('output'));
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(buffer.toString());
  stdout.writeln('Appcast written: ${output.path}');
}

Map<String, String> _parseXmlAttributes(String input) {
  return {
    for (final match in RegExp(
      r'([A-Za-z0-9:_-]+)="([^"]*)"',
    ).allMatches(input))
      match.group(1)!: match.group(2)!,
  };
}

_AppVersion _parseAppVersion(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError('App version is empty');
  }

  final parts = trimmed.split('+');
  final shortVersion = parts.first;
  final buildNumber = parts.length > 1 && parts[1].isNotEmpty
      ? parts[1]
      : shortVersion;
  return _AppVersion(trimmed, shortVersion, buildNumber);
}

String _readPubspecVersion() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final match = RegExp(
    r'^version:\s*([^\s#]+)',
    multiLine: true,
  ).firstMatch(pubspec);
  if (match == null) {
    throw StateError('pubspec.yaml does not contain a version field');
  }
  return match.group(1)!;
}

_Metadata _readMetadata(File file) {
  if (!file.existsSync()) {
    throw ArgumentError('Metadata file was not found: ${file.path}');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw ArgumentError(
      'Metadata file must contain a JSON object: ${file.path}',
    );
  }
  return _Metadata(decoded);
}

int _compareMetadata(_Metadata left, _Metadata right) {
  int platformRank(_Metadata metadata) {
    final platform = metadata.string('platform');
    final arch = metadata.string('arch');
    if (platform == 'windows') {
      return 0;
    }
    if (platform == 'macos' && arch == 'arm64') {
      return 1;
    }
    if (platform == 'macos' && arch == 'x64') {
      return 2;
    }
    return 3;
  }

  final byPlatform = platformRank(left).compareTo(platformRank(right));
  if (byPlatform != 0) {
    return byPlatform;
  }
  return left.string('fileName').compareTo(right.string('fileName'));
}

String _joinUrl(String baseUrl, String fileName) {
  final normalized = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
  return '$normalized${Uri.encodeComponent(fileName)}';
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash == -1 ? normalized : normalized.substring(slash + 1);
}

String _xmlText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _xmlAttribute(String value) =>
    _xmlText(value).replaceAll('"', '&quot;').replaceAll("'", '&apos;');

void _usage() {
  stderr.writeln('''
Usage:
  dart scripts/generate_appcast.dart metadata --platform <macos|windows> --artifact <path> --signature-file <path> --output <path> [--arch <arch>]
  dart scripts/generate_appcast.dart appcast --base-url <url> --output <path> <metadata.json>...
''');
}

class _AppVersion {
  const _AppVersion(this.raw, this.shortVersion, this.buildNumber);

  final String raw;
  final String shortVersion;
  final String buildNumber;
}

class _Metadata {
  const _Metadata(this.values);

  final Map<String, Object?> values;

  String string(String key) {
    final value = values[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw ArgumentError('Metadata field $key must be a non-empty string');
  }

  int intValue(String key) {
    final value = values[key];
    if (value is int) {
      return value;
    }
    throw ArgumentError('Metadata field $key must be an integer');
  }
}

class _ParsedArgs {
  const _ParsedArgs(this.options, this.rest);

  final Map<String, String> options;
  final List<String> rest;

  static _ParsedArgs parse(List<String> args) {
    final options = <String, String>{};
    final rest = <String>[];

    for (var i = 0; i < args.length; i += 1) {
      final arg = args[i];
      if (!arg.startsWith('--')) {
        rest.add(arg);
        continue;
      }

      final key = arg.substring(2);
      if (key.isEmpty) {
        throw ArgumentError('Empty option name');
      }
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        throw ArgumentError('Option --$key requires a value');
      }
      options[key] = args[i + 1];
      i += 1;
    }

    return _ParsedArgs(options, rest);
  }

  String requiredOption(String key) {
    final value = option(key);
    if (value == null || value.isEmpty) {
      throw ArgumentError('Missing required option --$key');
    }
    return value;
  }

  String? option(String key) => options[key];
}
