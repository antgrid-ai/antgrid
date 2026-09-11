import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/environment.dart';
import '../design/widgets/ab_snack_bar.dart';
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

Future<void> openSupportChat(BuildContext context, WidgetRef ref) async {
  if (ref.read(demoModeProvider)) {
    showAbSnackBar(context, 'Support chat is unavailable in demo mode.');
    return;
  }

  CurrentUser? user;
  try {
    user = await ref.read(currentUserProvider.future);
  } catch (_) {}
  if (context.mounted) {
    await openExternalUrl(
      context,
      supportChatUri(AppEnvironment.salesIqSupportUrl, user).toString(),
    );
  }
}
