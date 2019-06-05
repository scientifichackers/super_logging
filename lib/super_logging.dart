library super_logging;

import 'dart:async';
import 'dart:io';

import 'package:device_info/device_info.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:package_info/package_info.dart';
import 'package:path/path.dart' as pathlib;
import 'package:sentry/sentry.dart';

export 'package:sentry/sentry.dart' show User;

final _dateFmt = DateFormat("y-M-d");
final _sentryQueueController = StreamController<Event>();

typedef Future<User> GetCurrentUser(Map<String, String> deviceInfo);

void _log(String msg) {
  print("[super_logging] $msg");
}

class SuperLogging {
  static Map<String, String> deviceInfo;
  static String appVersion;
  static File logFile;

  static Future<Map<String, String>> getDeviceInfo() async {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      return {
        "manufacturer": info.manufacturer,
        "model": info.model,
        "product": info.product,
        "androidVersion": info.version.release,
        "supportedAbis": info.supportedAbis.toString(),
      };
    } else if (Platform.isIOS) {
      final info = await DeviceInfoPlugin().iosInfo;
      return {
        "name": info.name,
        "model": info.model,
        "systemName": info.systemName,
        "systemVersion": info.systemVersion,
      };
    }
    return {};
  }

  static Future<File> createLogFile(String logFileDir, int maxLogFiles) async {
    final dir = Directory(logFileDir);
    await dir.create(recursive: true);
    final logFile = File("$logFileDir/${_dateFmt.format(DateTime.now())}");
    final files = <File>[];

    for (final file in await dir.list().toList()) {
      try {
        _dateFmt.parse(pathlib.basename(file.path));
      } on FormatException catch (_) {
        continue;
      }
      files.add(file);
    }
    if (files.length > maxLogFiles) {
      files.sort((a, b) {
        return _dateFmt
            .parse(pathlib.basename(a.path))
            .compareTo(_dateFmt.parse(pathlib.basename(b.path)));
      });
      for (var file in files.sublist(0, files.length - maxLogFiles)) {
        await file.delete();
      }
    }

    return logFile;
  }

  static Future<void> _sentryUploadLoop(
    SentryClient sentry,
    Duration sentryAutoRetryDelay,
  ) async {
    await for (final event in _sentryQueueController.stream) {
      SentryResponse response;
      try {
        response = await sentry.capture(event: event);
      } catch (e) {
        _log("sentry upload failed with: $e; retry in $sentryAutoRetryDelay");
        continue;
      }

      if (!response.isSuccessful) {
        Future.delayed(sentryAutoRetryDelay, () {
          _sentryQueueController.add(event);
        });
      }
    }
  }

  static Future<void> _handleRec(
    LogRecord rec,
    GetCurrentUser getCurrentUser,
    bool sentryEnabled,
  ) async {
    var asStr = "[${rec.loggerName}] [${rec.level}] [${rec.time.toString()}] "
        "${rec.message}";

    if (rec.error != null) asStr += "\n${rec.error}\n${rec.stackTrace}\n";

    // write to stdout
    print(asStr);

    // write to logfile
    await logFile?.writeAsString(
      asStr,
      mode: FileMode.append,
      flush: true,
    );

    // add error to sentry queue
    if (sentryEnabled && rec.error != null) {
      final user = await getCurrentUser?.call(deviceInfo);
      _sentryQueueController.add(
        Event(
          release: appVersion,
          level: SeverityLevel.error,
          culprit: rec.message,
          loggerName: rec.loggerName,
          exception: rec.error,
          stackTrace: rec.stackTrace,
          userContext: user ?? User(extras: deviceInfo),
        ),
      );
    }
  }

  static Future<void> _mainloop(
    GetCurrentUser getCurrentUser,
    bool sentryEnabled,
  ) async {
    Logger.root.level = Level.ALL;
    await for (final rec in Logger.root.onRecord) {
      await _handleRec(rec, getCurrentUser, sentryEnabled);
    }
  }

  static bool get isInDebugMode {
    var value = false;
    assert(value = true);
    return value;
  }

  static Future<void> init({
    String sentryDsn,
    Duration sentryAutoRetryDelay: const Duration(seconds: 10),
    GetCurrentUser getCurrentUser,
    String logFileDir,
    int maxLogFiles: 10,
    bool considerDebugMode: false,
    Function run,
  }) async {
    final shouldDisable = considerDebugMode && isInDebugMode;
    if (shouldDisable) {
      _log("detected debug mode; sentry & file logging will be disabled!");
    }

    appVersion = (await PackageInfo.fromPlatform()).version;
    _log("appVersion: $appVersion");

    deviceInfo = await getDeviceInfo();
    _log("deviceInfo: $deviceInfo");

    if (!shouldDisable && logFileDir != null) {
      logFile = await createLogFile(logFileDir, maxLogFiles);
      _log("log file for this session: $logFile");
    }

    if (!shouldDisable && sentryDsn != null) {
      _sentryUploadLoop(SentryClient(dsn: sentryDsn), sentryAutoRetryDelay);
      _log("sentry uploader initialized");
    }

    _mainloop(getCurrentUser, sentryDsn != null);
    _log("mainloop started");

    if (run == null) return;
    final l = Logger("super_logging");

    if (shouldDisable) {
      await run();
    } else {
      FlutterError.onError = (errorDetails) {
        l.fine(
          "uncaught error at FlutterError.onError()",
          errorDetails.exception,
          errorDetails.stack,
        );
      };
      runZoned(() async {
        await run();
      }, onError: (e, trace) {
        l.fine("uncaught error at runZoned()", e, trace);
      });
    }
  }
}
