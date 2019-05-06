# Super Logging

The usual dart logging module with superpowers!

[![Sponsor](https://img.shields.io/badge/Sponsor-jaaga_labs-red.svg?style=for-the-badge)](https://www.jaaga.in/labs)

[![pub package](https://img.shields.io/pub/v/super_logging.svg?style=for-the-badge)](https://pub.dartlang.org/packages/super_logging)

This will log to
- stdout
- disk
- sentry.io

## How do I use this?

```dart
import 'package:super_logging/super_logging.dart';  // you only need this import for initialize
import 'package:logging/logging.dart';  // this is the regular dart module

final _logger = Logger("main");

main() async {
  // you must initalize before using the logger!
  await SuperLogging.init();
  
  _logger.info("hello!");
}
```

This will log to stdout by default. Use may also choose to :-

### Use sentry.io

This module can upload errors to sentry.io if you want.

(Errors can be logged by passing errors like so: `_logger.fine(msg, e, trace);`)

```dart
await SuperLogging.init(
  // Passing this will enable sentry uploads.
  sentryDsn: "YOUR_SENTRY_DSN",

  // [optional] Has auto retry of uploads built right in!
  sentryAutoRetryDelay: Duration(seconds: 5),
  
  // [optional] Get current user info, which will be sent to sentry.
  // This appears in their web gui.
  getCurrentUser: (deviceInfo) {
    return User(
      username: "john",
      extras: deviceInfo,  // contains valuable info like device manufacturer, model etc.
    )
  },
  
  // [optional] automatically turn off sentry/file logging during debug mode.
  bool considerDebugMode: true,
)
```

### Use the disk

```dart
await SuperLogging.init(
  // Passing this will enable logging to the disk.
  // New log files are created every day.
  String logFileDir: "LOGGING_DIRECORY",

  // This controls the max no of log files inside [logFileDir].
  // This prevents log files blowing up.
  // Older log files are deleted automatically.
  int maxLogFiles: 10,
)
```

## Can I log uncaught errors?

Yes! just do the following, along with `SuperLogger.init()`

```dart
import 'package:super_logging/super_logging.dart';
import 'package:logging/logging.dart';

final _logger = Logger("main");

main() async {
  await SuperLogging.init();

  // catch all errors from flutter
  FlutterError.onError = (errorDetails) {
    _logger.fine(
      "error caught inside `FlutterError.onError()`",
      errorDetails.exception,
      errorDetails.stack,
    );
  };

  runZoned(() {
    runApp(Main());  // `Main` is the root widget
  }, onError: (e, trace) {
    _logger.fine("error caught inside `main()` run zone", e, trace);
  }); 
}
```

