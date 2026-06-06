import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class AppLogEntry {
  const AppLogEntry({
    required this.time,
    required this.level,
    required this.scope,
    required this.message,
    required this.context,
  });

  final DateTime time;
  final String level;
  final String scope;
  final String message;
  final Map<String, Object?> context;

  String get humanLine {
    final contextText = context.isEmpty
        ? ''
        : ' ${jsonEncode(_jsonEncodableContext(context))}';
    return '[${time.toIso8601String()}] [$level] [$scope] $message$contextText';
  }

  Map<String, Object?> toJson() {
    return {
      'time': time.toIso8601String(),
      'level': level,
      'scope': scope,
      'message': message,
      'context': _jsonEncodableContext(context),
    };
  }
}

Map<String, Object?> _jsonEncodableContext(Map<String, Object?> input) {
  final output = <String, Object?>{};
  for (final entry in input.entries) {
    output[entry.key] = _encodableValue(entry.value);
  }
  return output;
}

Object? _encodableValue(Object? value) {
  if (value == null ||
      value is String ||
      value is num ||
      value is bool ||
      value is List ||
      value is Map) {
    return value;
  }
  return value.toString();
}

class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  static const int _maxInMemoryEntries = 200;
  static const int _retainDays = 7;

  final ListQueue<AppLogEntry> _recent = ListQueue<AppLogEntry>();
  final ValueNotifier<List<AppLogEntry>> recentEntries =
      ValueNotifier<List<AppLogEntry>>(const <AppLogEntry>[]);

  bool _initialized = false;
  Directory? _logDir;
  IOSink? _sink;
  String? _sinkDate;
  Future<void> _fileWriteSerial = Future<void>.value();

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _logDir = await _resolveLogDirectory();
    await _logDir!.create(recursive: true);
    await _cleanupOldLogs();
    _initialized = true;
    info('logger', 'Logger initialized', context: {'directory': _logDir!.path});
  }

  void debug(
    String scope,
    String message, {
    Map<String, Object?> context = const {},
  }) {
    _write('DEBUG', scope, message, context: context);
  }

  void info(
    String scope,
    String message, {
    Map<String, Object?> context = const {},
  }) {
    _write('INFO', scope, message, context: context);
  }

  void warn(
    String scope,
    String message, {
    Map<String, Object?> context = const {},
  }) {
    _write('WARN', scope, message, context: context);
  }

  void error(
    String scope,
    String message, {
    Map<String, Object?> context = const {},
  }) {
    _write('ERROR', scope, message, context: context);
  }

  Future<File> exportDiagnostics() async {
    await initialize();
    final logDir = _logDir!;
    final now = DateTime.now();
    final fileName =
        'diagnostics-${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}.log';
    final outputFile = File('${logDir.path}${Platform.pathSeparator}$fileName');

    final buffer = StringBuffer()
      ..writeln('# EasyTier Pro diagnostics export')
      ..writeln('# generated_at=${now.toIso8601String()}')
      ..writeln('# log_dir=${logDir.path}')
      ..writeln();

    final files =
        logDir
            .listSync()
            .whereType<File>()
            .where(_isSourceLogFile)
            .toList(growable: false)
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      if (file.path == outputFile.path) {
        continue;
      }
      buffer.writeln('## FILE: ${file.path}');
      try {
        buffer.writeln(await file.readAsString());
      } catch (_) {
        buffer.writeln('<failed to read file>');
      }
      buffer.writeln();
    }

    await outputFile.writeAsString(buffer.toString(), flush: true);
    return outputFile;
  }

  String? get logDirectoryPath => _logDir?.path;

  List<AppLogEntry> get recentSnapshot =>
      List<AppLogEntry>.unmodifiable(_recent.toList(growable: false));

  void _write(
    String level,
    String scope,
    String message, {
    Map<String, Object?> context = const {},
  }) {
    final now = DateTime.now();
    final redactedContext = _redactMap(context);
    final entry = AppLogEntry(
      time: now,
      level: level,
      scope: scope,
      message: _redactText(message),
      context: redactedContext,
    );

    _recent.addLast(entry);
    while (_recent.length > _maxInMemoryEntries) {
      _recent.removeFirst();
    }
    recentEntries.value = List<AppLogEntry>.unmodifiable(
      _recent.toList(growable: false),
    );

    _fileWriteSerial = _fileWriteSerial.then((_) => _writeToFile(entry));
  }

  Future<void> _writeToFile(AppLogEntry entry) async {
    try {
      await initialize();
      final sink = await _ensureSink(entry.time);
      sink.writeln(jsonEncode(entry.toJson()));
      await sink.flush();
    } catch (error) {
      debugPrint('AppLogger write failure: $error');
    }
  }

  Future<IOSink> _ensureSink(DateTime now) async {
    final day =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    if (_sink != null && _sinkDate == day) {
      return _sink!;
    }

    await _sink?.flush();
    await _sink?.close();

    final file = File('${_logDir!.path}${Platform.pathSeparator}gui-$day.log');
    _sink = file.openWrite(mode: FileMode.append);
    _sinkDate = day;
    return _sink!;
  }

  Future<Directory> _resolveLogDirectory() async {
    if (Platform.isWindows) {
      final base = Platform.environment['LOCALAPPDATA'];
      if (base != null && base.isNotEmpty) {
        return Directory(
          '$base${Platform.pathSeparator}EasyTierPro${Platform.pathSeparator}logs',
        );
      }
    }

    if (Platform.isAndroid || Platform.isIOS) {
      return Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}easytier-pro-app${Platform.pathSeparator}logs',
      );
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(
        '$home${Platform.pathSeparator}.easytier-pro-app${Platform.pathSeparator}logs',
      );
    }

    return Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}easytier-pro-app${Platform.pathSeparator}logs',
    );
  }

  bool _isSourceLogFile(File file) {
    final segments = Uri.file(file.path).pathSegments;
    final name = segments.isEmpty ? file.path : segments.last;
    return name.endsWith('.log') && !name.startsWith('diagnostics-');
  }

  Future<void> _cleanupOldLogs() async {
    if (_logDir == null || !_logDir!.existsSync()) {
      return;
    }

    final cutoff = DateTime.now().subtract(const Duration(days: _retainDays));
    for (final entity in _logDir!.listSync()) {
      if (entity is! File || !entity.path.endsWith('.log')) {
        continue;
      }
      final modified = entity.lastModifiedSync();
      if (modified.isBefore(cutoff)) {
        try {
          entity.deleteSync();
        } catch (_) {
          // Best effort retention cleanup only.
        }
      }
    }
  }

  static const List<String> _sensitiveKeys = <String>[
    'token',
    'authorization',
    'secret',
    'password',
    'cookie',
    'bootstrap',
    'machine_id',
    'machine-id',
    'access_token',
    'refresh_token',
    'id_token',
  ];

  Map<String, Object?> _redactMap(Map<String, Object?> input) {
    final out = <String, Object?>{};
    for (final entry in input.entries) {
      final lowerKey = entry.key.toLowerCase();
      if (_sensitiveKeys.any(lowerKey.contains)) {
        out[entry.key] = '<redacted>';
      } else if (entry.value is Map<String, Object?>) {
        out[entry.key] = _redactMap(entry.value! as Map<String, Object?>);
      } else if (entry.value is String) {
        out[entry.key] = _redactText(entry.value! as String);
      } else {
        out[entry.key] = entry.value;
      }
    }
    return out;
  }

  String _redactText(String input) {
    var value = input;
    value = value.replaceAllMapped(
      RegExp(r'(authorization\s*:\s*bearer\s+)[^\s,;]+', caseSensitive: false),
      (match) => '${match.group(1)}<redacted>',
    );
    value = value.replaceAllMapped(
      RegExp(r'(bootstrap[_-]?token\s*[=:]\s*)[^\s,;]+', caseSensitive: false),
      (match) => '${match.group(1)}<redacted>',
    );
    value = value.replaceAllMapped(
      RegExp(r'(access[_-]?token\s*[=:]\s*)[^\s,;]+', caseSensitive: false),
      (match) => '${match.group(1)}<redacted>',
    );
    return value;
  }
}
