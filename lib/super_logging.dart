library super_logging;

import 'dart:async';
import 'dart:io';

import 'package:device_info/device_info.dart';
import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:package_info/package_info.dart';
import 'package:path/path.dart' as pathlib;
import 'package:sentry/sentry.dart';

export 'package:sentry/sentry.dart' show User;

final _dateFmt = DateFormat("y-M-d");

typedef Future<User> GetCurrentUser(Map<String, String> deviceInfo);

void _log(String msg) {
  print("[logging_plus] $msg");
}

class SuperLogging {
  Map<String, String> deviceInfo;
  String appVersion;
  File logFile;

  final _sentryQueueController = StreamController<Event>();

  SuperLogging._internal();

  static final instance = SuperLogging._internal();

  Future<Map<String, String>> getDeviceInfo() async {
    var info = await DeviceInfoPlugin().androidInfo;
    return {
      "manufacturer": info.manufacturer,
      "model": info.model,
      "product": info.product,
      "androidVersion": info.version.release,
      "supportedAbis": info.supportedAbis.toString(),
    };
  }

  Future<File> createLogFile(String logFileDir, int maxLogFiles) async {
    final dir = Directory(logFileDir),
        logFile = File("$logFileDir/${_dateFmt.format(DateTime.now())}"),
        files = <File>[];

    for (var file in await dir.list().toList()) {
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

  Future<void> _sentryUploadLoop(
    SentryClient sentry,
    Duration sentryAutoRetryDelay,
  ) async {
    await for (var event in _sentryQueueController.stream) {
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

  Future<void> _handleRec(LogRecord rec, GetCurrentUser getCurrentUser) async {
    var asStr = "[${rec.loggerName}] [${rec.level}] [${rec.time.toString()}] "
        "${rec.message}";

    if (rec.error != null) asStr += "\n${rec.error}\n${rec.stackTrace}\n";

    // write to stdout
    debugPrint(asStr);

    // write to logfile
    await logFile?.writeAsString(
      asStr,
      mode: FileMode.append,
      flush: true,
    );

    // add error to sentry queue
    if (rec.error != null) {
      final user = await getCurrentUser(deviceInfo);
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

  Future<void> init({
    String sentryDsn,
    Duration sentryAutoRetryDelay: const Duration(seconds: 10),
    GetCurrentUser getCurrentUser,
    String logFileDir,
    int maxLogFiles: 10,
  }) async {
    appVersion = (await PackageInfo.fromPlatform()).version;
    _log("appVersion: $appVersion");

    deviceInfo = await getDeviceInfo();
    _log("deviceInfo: $deviceInfo");

    if (logFileDir != null) {
      logFile = await createLogFile(logFileDir, maxLogFiles);
      _log("log file for this session: $logFile");
    }

    if (sentryDsn != null) {
      _sentryUploadLoop(SentryClient(dsn: sentryDsn), sentryAutoRetryDelay);
      _log("sentry uploader initialized.");
    }

    Logger.root.level = Level.ALL;
    () async {
      await for (var rec in Logger.root.onRecord) {
        await _handleRec(rec, getCurrentUser);
      }
    }();
  }
}
