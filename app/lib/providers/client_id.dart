import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Stable per-install id used to attribute terminal:resize requests to a driver.
/// Opaque to the bridge — any stable string distinguishing this install from
/// other devices works; decoupled from auth/device provisioning so it is
/// available before sign-in.
const _clientIdKey = 'antgrid.client_id.v1';

final clientIdProvider = FutureProvider<String>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(_clientIdKey);
  if (existing != null) return existing;
  final fresh = const Uuid().v4();
  await prefs.setString(_clientIdKey, fresh);
  return fresh;
});
