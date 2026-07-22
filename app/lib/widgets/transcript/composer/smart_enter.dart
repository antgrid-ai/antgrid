/// What a hardware Enter keydown does in the rich composer.
enum EnterAction {
  /// Submit the prompt.
  send,

  /// Let fleather handle the key (newline / block continuation / list exit).
  fallthrough,
}

/// Smart-Enter policy. [caretLineIsPlain] is true only for an unformatted
/// paragraph; any formatted line — list, code, quote, or heading — is not
/// plain and falls through, so Enter continues the block / drops a newline
/// under a heading instead of sending mid-thought.
EnterAction decideEnter({
  required bool caretLineIsPlain,
  required bool isShift,
  required bool isCtrlOrCmd,
  required bool hasHardwareKeyboard,
}) {
  // Soft-keyboard Enter never sends: mobile submits via the Send button.
  if (!hasHardwareKeyboard) return EnterAction.fallthrough;
  if (isCtrlOrCmd) return EnterAction.send;
  if (isShift) return EnterAction.fallthrough;
  if (!caretLineIsPlain) return EnterAction.fallthrough;
  return EnterAction.send;
}
