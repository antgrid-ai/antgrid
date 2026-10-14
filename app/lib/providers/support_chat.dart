import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/environment.dart';
import '../services/auth_service.dart';
import '../util/external_url.dart';
import 'auth.dart';
import 'demo_mode.dart';

Uri supportChatUri(String baseUrl, CurrentUser? user) {
  final base = Uri.parse(baseUrl);
  final query = <String, String>{
    ...base.queryParameters,
    'chat': '1',
    'source': 'app',
  };
  final identity = <String, String>{
    if (user?.name?.trim().isNotEmpty ?? false) 'name': user!.name!.trim(),
    if (user != null) 'email': user.email,
  };
  final target = base.removeFragment().replace(queryParameters: query);
  if (identity.isEmpty) return target;
  return target.replace(fragment: Uri(queryParameters: identity).query);
}

Future<void> openSupportChat(
  BuildContext context,
  WidgetRef ref, {
  Future<void> Function(BuildContext, String) open = openExternalUrl,
}) async {
  CurrentUser? user;
  // Anonymous in the sample project even for a signed-in user (it is entered
  // from Recent and the setup checklist too): fetching the user reads the
  // stored session and calls the account service, which the demo never does.
  if (!ref.read(demoModeProvider)) {
    try {
      user = await ref.read(currentUserProvider.future);
    } catch (_) {}
  }
  if (context.mounted) {
    await open(
      context,
      supportChatUri(AppEnvironment.salesIqSupportUrl, user).toString(),
    );
  }
}
