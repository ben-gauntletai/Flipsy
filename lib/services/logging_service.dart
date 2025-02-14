import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

class LoggingService {
  static final LoggingService _instance = LoggingService._internal();
  static bool _forceDebugMode = true; // Always force debug mode

  factory LoggingService() {
    return _instance;
  }

  LoggingService._internal() {
    debugPrint('🚀 LOGGING SERVICE INITIALIZED 🚀');
    developer.log('LOGGING SERVICE INITIALIZED', name: 'FLIPSY_INIT');
  }

  static void log(
    String message, {
    String? name,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final timestamp = DateTime.now().toIso8601String();
    final logMessage = '[$timestamp] [$name]: $message';

    // Always print regardless of debug mode
    debugPrint('\n🔥 FLIPSY LOG 🔥');
    debugPrint(logMessage);
    if (error != null) {
      debugPrint('❌ ERROR DETAILS ❌');
      debugPrint('Error: $error');
      debugPrint('📚 StackTrace: \n$stackTrace');
    }
    debugPrint(''); // Empty line for better readability

    // Use dart:developer log for DevTools
    developer.log(
      message,
      name: name ?? 'FLIPSY',
      error: error,
      stackTrace: stackTrace,
      level: error != null ? 1000 : 0, // Use error level for errors
    );
  }

  static void logError(
    String message, {
    String? name,
    Object? error,
    StackTrace? stackTrace,
  }) {
    log(
      '‼️ ERROR: $message',
      name: name,
      error: error,
      stackTrace: stackTrace ?? StackTrace.current,
    );
  }

  static void logWarning(
    String message, {
    String? name,
    Object? error,
    StackTrace? stackTrace,
  }) {
    log(
      '⚠️ WARNING: $message',
      name: name,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void logInfo(
    String message, {
    String? name,
  }) {
    log(
      'ℹ️ INFO: $message',
      name: name,
    );
  }

  static void logSuccess(
    String message, {
    String? name,
  }) {
    log(
      '✅ SUCCESS: $message',
      name: name,
    );
  }

  static void logDebug(
    String message, {
    String? name,
    Object? data,
  }) {
    log(
      '🔍 DEBUG: $message${data != null ? '\nData: $data' : ''}',
      name: name,
    );
  }
}
