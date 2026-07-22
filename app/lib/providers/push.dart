import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/push_messaging_service.dart';

/// The single app-wide [PushMessagingService]. Shared so the sign-out flow
/// resets the SAME instance that startup registered on (see `main.dart`): a
/// fresh instance would leave the registration instance's cached token and
/// registered-set intact, so a re-sign-in without an app restart would skip
/// re-registration and push would silently stay dead.
final pushMessagingServiceProvider = Provider<PushMessagingService>((ref) {
  final service = PushMessagingService();
  ref.onDispose(service.dispose);
  return service;
});
