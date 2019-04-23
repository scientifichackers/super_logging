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
import 'package:super_logging/super_logging.dart';

main() async {
  await SuperLogging.init();
}
```

### use sentry.io

This module can upload errors to sentry.io if you want.

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
)
```

## use the disk

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
