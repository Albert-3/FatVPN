import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatvpn_app/services/app_logger.dart';

/// Regression test for the bug found on the emulator (2026-08-02): the logger
/// threw on every error it was asked to record.
///
/// `IOSink.flush()` binds the sink until its future completes, and writing into
/// a bound sink throws `Bad state: StreamSink is bound to a stream`.
/// [AppLogger.e] writes two lines — the message, then the stack — and the first
/// one starts the error flush, so the second one landed inside that window
/// every single time. `main()` calls `log.e` from `FlutterError.onError`, which
/// meant the throw happened *inside the error handler*: the framework error
/// being reported never reached the console or the file, and the frame it was
/// raised in was abandoned. On the split-tunnelling screen that showed up as a
/// blank list, with nothing in the log to say why.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('fatvpn_logger_test');
    // path_provider has no Android implementation in a host test; answer its
    // channel with a real temp directory so the sink is a real file sink —
    // an in-memory fake would not reproduce the bug at all.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
    await AppLogger.instance.init();
  });

  /// Everything the logger has actually put on disk.
  String logText() {
    final logDir = Directory('${dir.path}${Platform.pathSeparator}fatvpn_logs');
    final files = logDir.listSync().whereType<File>().toList();
    expect(files, isNotEmpty, reason: 'the logger should have opened a file');
    return files.map((f) => f.readAsStringSync()).join('\n');
  }

  test('logging an error with a stack trace does not throw', () {
    final before = AppLogger.instance.inMemoryCount;

    expect(
      () => AppLogger.instance
          .e('boom', StateError('nope'), StackTrace.current),
      returnsNormally,
    );

    // Both lines land: the message (with the error appended) and the stack.
    expect(AppLogger.instance.inMemoryCount, before + 2);
    expect(AppLogger.instance.lines.last, contains('ERROR'));
    expect(
      AppLogger.instance.lines[AppLogger.instance.lines.length - 2],
      contains('boom'),
    );
  });

  test('a burst of errors still does not throw', () {
    expect(
      () {
        for (var i = 0; i < 20; i++) {
          AppLogger.instance.e('burst $i', 'err', StackTrace.current);
        }
      },
      returnsNormally,
    );
  });

  test('an awaited flush waits for the one already in flight', () async {
    // `e()` fires an unawaited flush of its own, so any flush() called just
    // after an error used to find one in flight — and *return* rather than
    // join it. The caller got a completed future with nothing on disk. On a
    // phone that is the support bundle missing the last lines before a
    // force-quit: exactly the lines someone went looking for.
    AppLogger.instance.e('trigger', 'err', StackTrace.current);
    AppLogger.instance.i('after the error');

    await AppLogger.instance.flush();

    expect(logText(), contains('after the error'));
  });

  test('lines written while a flush is in flight reach the file', () async {
    AppLogger.instance.i('before the flush');
    final flushing = AppLogger.instance.flush();
    // Written inside the window where the sink is bound — this is the call
    // that used to throw.
    AppLogger.instance.i('during the flush');
    await flushing;
    await AppLogger.instance.flush();

    final text = logText();
    expect(text, contains('before the flush'));
    expect(text, contains('during the flush'));
  });
}
