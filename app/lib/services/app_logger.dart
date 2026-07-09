import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Severity of a log line, ordered least → most severe.
enum LogLevel { debug, info, warning, error }

extension _LogLevelLabel on LogLevel {
  String get label => switch (this) {
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO',
        LogLevel.warning => 'WARNING',
        LogLevel.error => 'ERROR',
      };
}

/// App-wide diagnostics logger.
///
/// Keeps the most recent [_maxInMemory] lines in a ring buffer (so a support
/// bundle can be assembled instantly, offline) and mirrors every line to a
/// rotating on-disk file so a crash or force-quit doesn't lose the trail. The
/// [Send] button in Settings turns this into a shareable text bundle with a
/// device/settings/session header — modelled on the SOTA support bundle.
///
/// Use the top-level [log] getter: `log.i('message')`. Safe to call before
/// [init] completes — early lines buffer in memory and are flushed to the file
/// once it opens.
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const _maxInMemory = 1000;
  static const _maxFiles = 5;
  static const _dirName = 'fatvpn_logs';

  final ListQueue<String> _buffer = ListQueue<String>();
  IOSink? _sink;
  File? _currentFile;
  Directory? _logDir;
  bool _initStarted = false;
  final Completer<void> _ready = Completer<void>();

  /// Opens (or rotates into) the on-disk log file. Idempotent — call once from
  /// `main`. Never throws: if the platform has no writable documents dir we
  /// fall back to in-memory-only logging.
  Future<void> init() async {
    if (_initStarted) return _ready.future;
    _initStarted = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}${Platform.pathSeparator}$_dirName');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _logDir = dir;
      await _pruneOldFiles(dir);

      final stamp = _fileStamp(DateTime.now());
      final file = File('${dir.path}${Platform.pathSeparator}fatvpn_$stamp.log');
      final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      sink.writeln('LOG STARTED: ${DateTime.now().toIso8601String()}');
      // Flush anything buffered before the file was ready.
      for (final line in _buffer) {
        sink.writeln(line);
      }
      _currentFile = file;
      _sink = sink;
    } catch (e) {
      // File logging is best-effort; keep buffering in memory.
      _record(LogLevel.warning, 'AppLogger: file logging unavailable ($e)');
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  void d(String message) => _record(LogLevel.debug, message);
  void i(String message) => _record(LogLevel.info, message);
  void w(String message) => _record(LogLevel.warning, message);
  void e(String message, [Object? error, StackTrace? stack]) {
    final suffix = error == null ? '' : ' — $error';
    _record(LogLevel.error, '$message$suffix');
    if (stack != null) _record(LogLevel.error, stack.toString());
  }

  void _record(LogLevel level, String message) {
    final line = '[${DateTime.now().toIso8601String()}] [${level.label}] $message';
    if (_buffer.length >= _maxInMemory) _buffer.removeFirst();
    _buffer.addLast(line);
    _sink?.writeln(line);
    if (kDebugMode) debugPrint(line);
  }

  /// Number of lines currently held in memory.
  int get inMemoryCount => _buffer.length;

  /// A snapshot of the in-memory lines, oldest first.
  List<String> get lines => List<String>.unmodifiable(_buffer);

  /// Clears the in-memory buffer and truncates the on-disk log files. Used by
  /// the Settings "Clear" button.
  Future<void> clear() async {
    _buffer.clear();
    try {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
      final dir = _logDir;
      if (dir != null && await dir.exists()) {
        await for (final entry in dir.list()) {
          if (entry is File) {
            try {
              await entry.delete();
            } catch (_) {}
          }
        }
      }
      // Re-open a fresh current file so logging continues after a clear.
      if (dir != null) {
        final stamp = _fileStamp(DateTime.now());
        final file = File('${dir.path}${Platform.pathSeparator}fatvpn_$stamp.log');
        final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
        sink.writeln('LOG STARTED: ${DateTime.now().toIso8601String()}');
        _currentFile = file;
        _sink = sink;
      }
    } catch (_) {
      // Best-effort; in-memory buffer is already cleared.
    }
    i('AppLogger: logs cleared by user');
  }

  /// Builds the full support-bundle text: a header (app / device / settings /
  /// session snapshot supplied via [extraContext]) followed by the in-memory
  /// log lines. [extraContext] is a caller-provided, already-sanitized map
  /// (mask tokens/keys before passing them in).
  Future<String> buildSupportBundle({
    Map<String, String> extraContext = const {},
  }) async {
    final app = await _appInfo();
    final device = await _deviceInfo();
    final b = StringBuffer();

    b.writeln('=== FATVPN SUPPORT BUNDLE ===');
    b.writeln('ExportedAt: ${DateTime.now().toIso8601String()}');
    b.writeln('Platform: ${_platformName()}');
    b.writeln('Locale: ${Platform.localeName}');
    b.writeln('BuildMode: ${kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug')}');
    b.writeln();

    b.writeln('--- APP ---');
    app.forEach((k, v) => b.writeln('$k: $v'));
    b.writeln();

    b.writeln('--- DEVICE ---');
    device.forEach((k, v) => b.writeln('$k: $v'));
    b.writeln();

    if (extraContext.isNotEmpty) {
      b.writeln('--- CONTEXT ---');
      final keys = extraContext.keys.toList()..sort();
      for (final k in keys) {
        b.writeln('$k: ${extraContext[k]}');
      }
      b.writeln();
    }

    b.writeln('--- LOG SUMMARY ---');
    b.writeln('in_memory_logs_count: ${_buffer.length}');
    b.writeln('in_memory_max: $_maxInMemory');
    b.writeln('file_logging_active: ${_sink != null}');
    b.writeln('current_log_file: ${_currentFile?.path ?? '(none)'}');
    b.writeln();

    b.writeln('=== LOGS ===');
    for (final line in _buffer) {
      b.writeln(line);
    }

    return b.toString();
  }

  /// Writes the bundle to a temp file and opens the OS share sheet. Awaits only
  /// the bundle build + file write (the part worth showing a spinner for), then
  /// launches the sheet fire-and-forget: on some Android builds the share future
  /// never completes when the sheet is dismissed without picking a target, which
  /// would otherwise wedge a caller that awaits it. Returns false if the bundle
  /// couldn't be prepared.
  Future<bool> shareSupportBundle({
    Map<String, String> extraContext = const {},
    String subject = 'FatVPN diagnostics',
  }) async {
    final bundle = await buildSupportBundle(extraContext: extraContext);
    try {
      final tmp = await getTemporaryDirectory();
      final stamp = _fileStamp(DateTime.now());
      final file = File('${tmp.path}${Platform.pathSeparator}fatvpn_logs_$stamp.txt');
      await file.writeAsString(bundle, flush: true);
      unawaited(_launchShare(
        [XFile(file.path, mimeType: 'text/plain')],
        subject,
      ));
      return true;
    } catch (err) {
      e('AppLogger: failed to prepare support bundle', err);
      return false;
    }
  }

  Future<void> _launchShare(List<XFile> files, String subject) async {
    try {
      await Share.shareXFiles(files, subject: subject);
    } catch (err) {
      e('AppLogger: share sheet error', err);
    }
  }

  Future<Map<String, String>> _appInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return {
        'appName': info.appName,
        'packageName': info.packageName,
        'version': info.version,
        'buildNumber': info.buildNumber,
      };
    } catch (err) {
      return {'error': 'package_info unavailable ($err)'};
    }
  }

  Future<Map<String, String>> _deviceInfo() async {
    final plugin = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        return {
          'os': 'Android ${a.version.release} (SDK ${a.version.sdkInt})',
          'model': '${a.manufacturer} ${a.model}',
          'device': a.device,
          'isPhysicalDevice': a.isPhysicalDevice.toString(),
        };
      }
      if (Platform.isIOS) {
        final ios = await plugin.iosInfo;
        return {
          'os': '${ios.systemName} ${ios.systemVersion}',
          'model': ios.utsname.machine,
          'name': ios.name,
          'isPhysicalDevice': ios.isPhysicalDevice.toString(),
        };
      }
    } catch (err) {
      return {'error': 'device_info unavailable ($err)'};
    }
    return {'os': Platform.operatingSystem};
  }

  String _platformName() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return Platform.operatingSystem;
  }

  /// Filesystem-safe timestamp for file names (`:` is illegal on Windows/iOS).
  String _fileStamp(DateTime t) =>
      t.toIso8601String().replaceAll(':', '-').replaceAll('.', '-');

  /// Keeps only the newest [_maxFiles] logs so the directory can't grow without
  /// bound across many launches.
  Future<void> _pruneOldFiles(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.log'))
          .cast<File>()
          .toList();
      if (files.length < _maxFiles) return;
      files.sort((a, b) => a.path.compareTo(b.path));
      final excess = files.length - (_maxFiles - 1);
      for (var i = 0; i < excess; i++) {
        try {
          await files[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// Short alias so call sites read `log.i(...)`.
AppLogger get log => AppLogger.instance;
