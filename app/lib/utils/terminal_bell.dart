import 'package:flutter/services.dart';

import 'platform_utils.dart';

/// Minimum gap between audible bells. Mirrors the bridge scanner's former
/// per-terminal bell throttle so a BEL flood (a `cat` of a binary file, a
/// misbehaving TUI) can't machine-gun the system alert. Global across terminals
/// on purpose: the user hears at most one bell per window regardless of how
/// many terminals would ring.
const _bellThrottle = Duration(milliseconds: 500);
DateTime? _lastBellAt;

/// Rings the terminal bell (BEL / `\a`) the way a native terminal does: an
/// audible system alert, plus a short haptic on mobile where there is no system
/// beep to rely on. Fire-and-forget — playback failures are non-fatal and must
/// never interrupt terminal output.
///
/// This is the ONLY effect of a bare BEL now: the bridge no longer turns it into
/// a desktop notification (only OSC 9/777 do that), so the bell behaves like any
/// other terminal's — you hear it, you are not "notified". Throttled so a burst
/// of BELs doesn't storm the alert; callers gate on focus (only the viewed
/// terminal rings).
void ringTerminalBell() {
  final now = DateTime.now();
  final last = _lastBellAt;
  if (last != null && now.difference(last) < _bellThrottle) return;
  _lastBellAt = now;
  SystemSound.play(SystemSoundType.alert);
  if (isMobilePlatform) HapticFeedback.mediumImpact();
}
