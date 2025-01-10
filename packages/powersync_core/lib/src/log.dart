import 'package:logging/logging.dart';
import 'package:powersync_core/src/log_internal.dart';

/// Logger that outputs to the console in debug mode, and nothing
/// in release and profile modes.
final Logger autoLogger = _makeAutoLogger();

/// Logger that always outputs debug info to the console.
final Logger debugLogger = _makeDebugLogger();

/// Standard logger. Does not automatically log to the console,
/// use the `Logger.root.onRecord` stream to get log messages.
final Logger attachedLogger = Logger('PowerSync');

Logger _makeDebugLogger() {
  final logger = Logger.detached('PowerSync');
  logger.level = Level.OFF;
  return logger;
}

Logger _makeAutoLogger() {
  final logger = Logger.detached('PowerSync');
  logger.level = Level.OFF;
  return logger;
}
