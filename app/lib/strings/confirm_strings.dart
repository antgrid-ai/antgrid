/// Shared copy for destructive-action confirm dialogs. Lifted out of widgets
/// so mobile and desktop call sites can't drift apart.
abstract final class ConfirmStrings {
  // Forget a "recent" agent — trust record only, no active connection.
  static String forgetTitle(String agentLabel) => 'Forget $agentLabel?';
  static const forgetBody =
      'This removes the saved trust relationship. '
      'You\'ll need to scan the QR code again to reconnect.';
  static const forgetConfirm = 'Forget';

  // Remove a currently-paired remote agent — unpairs and drops trust.
  static String removeRemoteTitle(String name) => 'Remove $name?';
  static const removeRemoteBody =
      'This will unpair the project. '
      'You\'ll need to scan the QR code again to reconnect.';
  static const removeRemoteConfirm = 'Remove';

  // Remove a local project entry — files on disk untouched.
  static String removeLocalTitle(String name) => 'Remove $name?';
  static const removeLocalBody =
      'This removes the project from your dashboard. '
      'Files on disk are not affected.';
  static const removeLocalConfirm = 'Remove';
}
