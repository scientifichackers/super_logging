// @dart=2.9
library super_logging;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sentry/sentry.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

export 'package:sentry/sentry.dart' show SentryUser;

typedef FutureOr<void> FutureOrVoidCallback();

extension SuperString on String {
  Iterable<String> chunked(int chunkSize) sync* {
    int start = 0;

    while (true) {
      int stop = start + chunkSize;
      if (stop > length) break;
      yield substring(start, stop);
      start = stop;
    }

    if (start < length) {
      yield substring(start);
    }
  }
}

extension SuperLogRecord on LogRecord {
  String toPrettyString([String extraLines]) {
    String header = "[$loggerName] [$level] [$time]";

    String msg = "$header $message";

    if (error != null) {
      msg += "\n⤷ type: ${error.runtimeType}\n⤷ error: $error";
    }
    if (stackTrace != null) {
      msg += "\n${FlutterError.demangleStackTrace(stackTrace)}";
    }

    for (String line in extraLines?.split('\n') ?? []) {
      msg += '\n$header $line';
    }

    return msg;
  }
}

final SuperLogging = _SuperLogging();

class SuperLoggingConfig {
  /// The DSN for a Sentry app.
  /// This can be obtained from the Sentry apps's "settings > Client Keys (DSN)" page.
  ///
  /// Only logs containing errors are sent to sentry.
  /// Errors can be caught using a try-catch block, like so:
  ///
  /// ```
  /// final logger = Logger("main");
  ///
  /// try {
  ///   // do something dangerous here
  /// } catch(e, trace) {
  ///   logger.info("Huston, we have a problem", e, trace);
  /// }
  /// ```
  ///
  /// If this is [null], Sentry logger is completely disabled (default).
  String sentryDsn;

  /// A built-in retry mechanism for sending errors to sentry.
  ///
  /// This parameter defines the time to wait for, before retrying.
  Duration sentryRetryDelay = const Duration(seconds: 30);

  /// Path of the directory where log files will be stored.
  ///
  /// If this is [null], file logging is completely disabled (default).
  ///
  /// If this is an empty string (['']),
  /// then a 'logs' directory will be created in [getTemporaryDirectory()].
  ///
  /// A non-empty string will be treated as an explicit path to a directory.
  ///
  /// The chosen directory can be accessed using [SuperLogging.logFile.parent].
  String logDirPath;

  /// The maximum number of log files inside [logDirPath].
  ///
  /// One log file is created per day.
  /// Older log files are deleted automatically.
  int maxLogFiles = 10;

  /// Whether to enable super logging features in debug mode.
  ///
  /// Sentry and file logging are typically not needed in debug mode,
  /// where a complete logcat is available.
  bool enableInDebugMode = false;

  /// The date format for storing log files.
  ///
  /// `DateFormat('y-M-d')` by default.
  DateFormat dateFmt = DateFormat("y-M-d");

  /// Allows filtering events that will be sent to sentry.
  ///
  /// The default behavior is to forward all errors.
  bool Function(LogRecord) sentryFilter = (rec) => rec.error != null;
}

class _SuperLogging {
  /// The logger for SuperLogging
  static final $ = Logger('super_logging');

  final SuperLoggingConfig config = SuperLoggingConfig();

  Future<void> main(FutureOrVoidCallback body) async {
    WidgetsFlutterBinding.ensureInitialized();

    appVersion ??= await getAppVersion();
    if (!kIsWeb) {
      deviceInfo ??= await getDeviceInfo();
    }
    user = userFactory();

    final enable = config.enableInDebugMode || kReleaseMode;
    _sentryIsEnabled = enable && config.sentryDsn != null;
    _fileIsEnabled = enable && config.logDirPath != null;

    if (_fileIsEnabled) {
      await setupLogDir();
    }
    if (_sentryIsEnabled) {
      sentryUploader();
    }

    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(onLogRecord);
    $.info("logger installed 💥");

    if (!enable) {
      $.info("detected debug mode; sentry & file logging disabled.");
    }
    if (_fileIsEnabled) {
      $.info("using this log file for today: $logFile");
    }
    if (_sentryIsEnabled) {
      $.info("sentry uploader started");
    }

    if (body == null) return;

    if (enable) {
      FlutterError.onError = (details) {
        $.fine(
          "uncaught flutter error",
          details.exception,
          details.stack,
        );
      };
      await SentryFlutter.init(
        (options) {
          options.dsn = config.sentryDsn;
        },
        // Init your App.
        appRunner: body,
      );
    } else {
      await body();
    }
  }

  String _lastExtraLines = '';

  Future onLogRecord(LogRecord rec) async {
    // log misc info, but only if it changed
    String extraLines =
        "app version: $appVersion\ncurrent user: ${user.toJson()}";
    if (extraLines != _lastExtraLines) {
      _lastExtraLines = extraLines;
    } else {
      extraLines = null;
    }

    String str = rec.toPrettyString(extraLines);

    // write to stdout
    printLog(str);

    // write to logfile
    if (_fileIsEnabled) {
      String strForLogFile = str + '\n';
      await logFile.writeAsString(
        strForLogFile,
        mode: FileMode.append,
        flush: true,
      );
    }

    // add error to sentry queue
    if (_sentryIsEnabled && config.sentryFilter(rec)) {
      sentryQueueControl.add(
        _SentryQueueItem(
          rec: rec,
          event: SentryEvent(
            release: appVersion,
            level: SentryLevel.error,
            culprit: rec.message,
            logger: rec.loggerName,
            throwable: rec.error,
            user: user,
          ),
        ),
      );
    }
  }

  // Logs on must be chunked or they get truncated otherwise
  // See https://github.com/flutter/flutter/issues/22665
  int logChunkSize = 800;

  void printLog(String text) {
    text.chunked(logChunkSize).forEach(print);
  }

  /// A queue to be consumed by [sentryUploader].
  final StreamController<_SentryQueueItem> sentryQueueControl =
      StreamController<_SentryQueueItem>();

  /// Whether sentry logging is currently enabled or not.
  bool _sentryIsEnabled;

  Future<void> sentryUploader() async {
    await for (_SentryQueueItem item in sentryQueueControl.stream) {
      try {
        await Sentry.captureEvent(item.event, stackTrace: item.rec.stackTrace);
      } catch (e) {
        $.fine(
          "sentry upload failed; will retry after ${config.sentryRetryDelay} (${e.runtimeType}: $e)",
        );
        doSentryRetry(item);
      }
    }
  }

  void doSentryRetry(_SentryQueueItem event) async {
    await Future.delayed(config.sentryRetryDelay);
    sentryQueueControl.add(event);
  }

  /// The log file currently in use.
  File logFile;

  /// Whether file logging is currently enabled or not.
  bool _fileIsEnabled;

  Future<void> setupLogDir() async {
    // choose log dir
    if (config.logDirPath.isEmpty) {
      Directory root = await getExternalStorageDirectory();
      config.logDirPath = '${root.path}/logs';
    }

    // create log dir
    Directory dir = Directory(config.logDirPath);
    await dir.create(recursive: true);

    List<File> files = <File>[];
    Map<File, DateTime> dates = <File, DateTime>{};

    // collect all log files with valid names
    await for (FileSystemEntity file in dir.list()) {
      try {
        DateTime date = config.dateFmt.parse(basename(file.path));
        dates[file] = date;
      } on FormatException {}
    }

    // delete old log files, if [maxLogFiles] is exceeded.
    if (files.length > config.maxLogFiles) {
      // sort files based on ascending order of date (older first)
      files.sort((a, b) => dates[a].compareTo(dates[b]));

      int extra = files.length - config.maxLogFiles;
      List<File> toDelete = files.sublist(0, extra);

      for (File file in toDelete) {
        await file.delete();
      }
    }

    logFile = File(
      "${config.logDirPath}/${config.dateFmt.format(DateTime.now())}.txt",
    );
  }

  /// The current user.
  ///
  /// See: [userFactory]
  SentryUser user;

  /// set the properties for current user.
  SentryUser userFactory({
    String id,
    String username,
    String email,
    Map<String, String> extraInfo,
  }) {
    extraInfo ??= {};
    if (deviceInfo != null) {
      extraInfo.putIfAbsent('deviceInfo', () => deviceInfo);
    }
    return SentryUser(
      id: id ?? '',
      username: username,
      email: email,
      extras: extraInfo,
    );
  }

  /// Current device information as a JSON string,
  /// obtained from device_info plugin.
  ///
  /// See: [getDeviceInfo]
  String deviceInfo;

  Future<String> getDeviceInfo() async {
    MethodChannel channel = MethodChannel('plugins.flutter.io/device_info');

    String method = '';
    if (Platform.isAndroid) {
      method = 'getAndroidDeviceInfo';
    } else if (Platform.isIOS) {
      method = 'getIosDeviceInfo';
    }

    if (method.isEmpty) {
      return '';
    }

    dynamic result = await channel.invokeMethod(method);
    String data = jsonEncode(result);

    return data;
  }

  /// Current app version, obtained from package_info plugin.
  ///
  /// See: [getAppVersion]
  String appVersion;

  Future<String> getAppVersion() async {
    PackageInfo pkgInfo = await PackageInfo.fromPlatform();
    return "${pkgInfo.version}+${pkgInfo.buildNumber}";
  }
}

class _SentryQueueItem {
  final SentryEvent event;
  final LogRecord rec;

  _SentryQueueItem({
    @required this.event,
    @required this.rec,
  });
}
