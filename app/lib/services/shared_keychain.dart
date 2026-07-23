import 'package:flutter/services.dart';

/// Read/write the push seed in a SHARED Keychain Access Group so the iOS
/// Notification Service Extension (a separate process) can read the same seed
/// the app wrote. iOS-only.
class SharedKeychain {
  static const _channel = MethodChannel('ai.radhaai.antgrid/keychain');

  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('write', {'key': key, 'value': value});

  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', {'key': key});

  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('delete', {'key': key});
}
