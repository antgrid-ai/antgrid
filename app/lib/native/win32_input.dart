import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../util/ab_log.dart';
import 'input_injector.dart';

/// Hand-rolled Win32 FFI for remote input injection.
///
/// Deliberately not `package:win32`: its `INPUT` union layout moved between
/// major versions, and a silently mis-sized struct here does not fail loudly —
/// `SendInput` just returns 0 and the remote peer's clicks vanish. These structs
/// are pinned to the documented x64 ABI instead, and the sizes are asserted.
///
/// No native plugin and no C++ in the build: everything below resolves out of
/// DLLs Windows already has loaded.

const String _component = 'Win32Input';

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');
final DynamicLibrary _dwmapi = DynamicLibrary.open('dwmapi.dll');

// --- structs ---------------------------------------------------------------

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

/// INPUT is 40 bytes on x64: a DWORD type, four bytes of padding, then a
/// 32-byte union whose largest member is MOUSEINPUT. Rather than model the
/// union, each variant is a separate 40-byte struct — `SendInput` only ever
/// sees `cbSize`, so a homogeneous batch of either is a valid INPUT array.
final class _MouseInput extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int pad0;
  @Int32()
  external int dx;
  @Int32()
  external int dy;
  @Uint32()
  external int mouseData;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @Uint32()
  external int pad1;
  @IntPtr()
  external int dwExtraInfo;
}

final class _KeybdInput extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int pad0;
  @Uint16()
  external int wVk;
  @Uint16()
  external int wScan;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @Uint32()
  external int pad1;
  @IntPtr()
  external int dwExtraInfo;
  // KEYBDINPUT is 8 bytes shorter than MOUSEINPUT; the union is not.
  @Uint32()
  external int tail0;
  @Uint32()
  external int tail1;
}

// --- constants -------------------------------------------------------------

const int _inputMouse = 0;
const int _inputKeyboard = 1;

const int _mouseEventMove = 0x0001;
const int _mouseEventLeftDown = 0x0002;
const int _mouseEventLeftUp = 0x0004;
const int _mouseEventRightDown = 0x0008;
const int _mouseEventRightUp = 0x0010;
const int _mouseEventMiddleDown = 0x0020;
const int _mouseEventMiddleUp = 0x0040;
const int _mouseEventWheel = 0x0800;
const int _mouseEventHWheel = 0x1000;
const int _mouseEventVirtualDesk = 0x4000;
const int _mouseEventAbsolute = 0x8000;

const int _keyEventExtended = 0x0001;
const int _keyEventKeyUp = 0x0002;
const int _keyEventUnicode = 0x0004;

/// One wheel notch.
const int _wheelDelta = 120;

const int _smXVirtualScreen = 76;
const int _smYVirtualScreen = 77;
const int _smCxVirtualScreen = 78;
const int _smCyVirtualScreen = 79;

const int _swRestore = 9;
const int _gaRoot = 2;

const int _gwlExStyle = -20;
const int _wsExToolWindow = 0x00000080;
const int _dwmwaCloaked = 14;

const int _processQueryLimitedInformation = 0x1000;
const int _tokenQuery = 0x0008;
const int _tokenIntegrityLevel = 25;

// --- bindings --------------------------------------------------------------

final _sendInput = _user32
    .lookupFunction<
      Uint32 Function(Uint32, Pointer, Int32),
      int Function(int, Pointer, int)
    >('SendInput');

final _getForegroundWindow = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');

final _setForegroundWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetForegroundWindow',
    );

final _bringWindowToTop = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'BringWindowToTop',
    );

final _getWindowRect = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<_Rect>),
      int Function(int, Pointer<_Rect>)
    >('GetWindowRect');

final _enumWindows = _user32
    .lookupFunction<
      Int32 Function(
        Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>,
        IntPtr,
      ),
      int Function(Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>, int)
    >('EnumWindows');

final _isWindowVisible = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindowVisible',
    );

final _getWindowTextLength = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'GetWindowTextLengthW',
    );

final _getWindowText = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, int)
    >('GetWindowTextW');

final _getWindowLongPtr = _user32
    .lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
      'GetWindowLongPtrW',
    );

final _dwmGetWindowAttribute = _dwmapi
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<Int32>, Uint32),
      int Function(int, int, Pointer<Int32>, int)
    >('DwmGetWindowAttribute');

final _isWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');

final _isIconic = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');

final _showWindow = _user32
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
      'ShowWindow',
    );

final _getWindowThreadProcessId = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');

final _attachThreadInput = _user32
    .lookupFunction<
      Int32 Function(Uint32, Uint32, Int32),
      int Function(int, int, int)
    >('AttachThreadInput');

final _getSystemMetrics = _user32
    .lookupFunction<Int32 Function(Int32), int Function(int)>(
      'GetSystemMetrics',
    );

final _getAncestor = _user32
    .lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
      'GetAncestor',
    );

final _getCurrentThreadId = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');

final _getCurrentProcessId = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');

final _openProcess = _kernel32
    .lookupFunction<
      IntPtr Function(Uint32, Int32, Uint32),
      int Function(int, int, int)
    >('OpenProcess');

final _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

final _openProcessToken = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
      int Function(int, int, Pointer<IntPtr>)
    >('OpenProcessToken');

final _getTokenInformation = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer, Uint32, Pointer<Uint32>),
      int Function(int, int, Pointer, int, Pointer<Uint32>)
    >('GetTokenInformation');

final _getSidSubAuthorityCount = _advapi32
    .lookupFunction<
      Pointer<Uint8> Function(Pointer<Void>),
      Pointer<Uint8> Function(Pointer<Void>)
    >('GetSidSubAuthorityCount');

final _getSidSubAuthority = _advapi32
    .lookupFunction<
      Pointer<Uint32> Function(Pointer<Void>, Uint32),
      Pointer<Uint32> Function(Pointer<Void>, int)
    >('GetSidSubAuthority');

// --- window queries --------------------------------------------------------

/// Screen rect of [hwnd], or null if the handle is dead.
///
/// The capture pipeline needs this to build a [FrameToScreenTransform]; note
/// that the captured frame is a crop of this rect, not the rect itself.
({int left, int top, int right, int bottom})? windowScreenRect(int hwnd) {
  final rect = calloc<_Rect>();
  try {
    if (_getWindowRect(hwnd, rect) == 0) return null;
    return (
      left: rect.ref.left,
      top: rect.ref.top,
      right: rect.ref.right,
      bottom: rect.ref.bottom,
    );
  } finally {
    calloc.free(rect);
  }
}

bool isLiveWindow(int hwnd) => hwnd != 0 && _isWindow(hwnd) != 0;

/// Whether [hwnd] is minimised.
///
/// A minimised window keeps `WS_VISIBLE`, so `IsWindowVisible` is not the check
/// — this is. libwebrtc's `WindowCapturerWinGdi::SelectSource` rejects an iconic
/// window, which makes `RTCDesktopCapturer::Start()` return `CS_FAILED`; the
/// flutter_webrtc plugin discards that return value, so the only symptom is a
/// track that never produces a frame.
bool isWindowMinimised(int hwnd) => hwnd != 0 && _isIconic(hwnd) != 0;

/// A minimised top-level window, which the capture backend cannot enumerate.
@immutable
class MinimisedWindow {
  const MinimisedWindow({required this.hwnd, required this.title});

  final int hwnd;
  final String title;
}

/// Accumulator for [enumerateMinimisedWindows]. Safe as a global only because
/// `EnumWindows` is synchronous and single-threaded: the callback has run to
/// completion before the call returns, and Dart cannot interleave another
/// enumeration into it.
List<MinimisedWindow> _enumAccumulator = [];

int _collectMinimised(int hwnd, int _) {
  // Minimised is the whole selection: everything libwebrtc already lists comes
  // from the capture backend, and duplicating it here would mean two sources of
  // truth for the same window.
  if (_isIconic(hwnd) == 0) return 1;
  if (_isWindowVisible(hwnd) == 0) return 1;
  if (_getAncestor(hwnd, _gaRoot) != hwnd) return 1;
  if (_getWindowLongPtr(hwnd, _gwlExStyle) & _wsExToolWindow != 0) return 1;
  if (_isCloaked(hwnd)) return 1;
  final title = _windowTitle(hwnd);
  if (title.isEmpty) return 1;
  _enumAccumulator.add(MinimisedWindow(hwnd: hwnd, title: title));
  return 1;
}

/// A window on another virtual desktop, or a suspended UWP app. Windows keeps
/// these visible-and-not-iconic in the classic API while showing nothing, so
/// they would otherwise be offered as shareable and then capture as blank.
bool _isCloaked(int hwnd) {
  final value = calloc<Int32>();
  try {
    if (_dwmGetWindowAttribute(hwnd, _dwmwaCloaked, value, 4) != 0) {
      return false;
    }
    return value.value != 0;
  } finally {
    calloc.free(value);
  }
}

String _windowTitle(int hwnd) {
  final length = _getWindowTextLength(hwnd);
  if (length <= 0) return '';
  final buffer = calloc<Uint16>(length + 1).cast<Utf16>();
  try {
    final written = _getWindowText(hwnd, buffer, length + 1);
    return written <= 0 ? '' : buffer.toDartString(length: written);
  } finally {
    calloc.free(buffer);
  }
}

/// The minimised top-level windows, which the capture backend omits.
///
/// libwebrtc drops these from `GetSourceList` because it cannot capture one —
/// `SelectSource` rejects an iconic window. Restoring it first makes it
/// capturable, so the omission is what stops a remote peer reaching the window
/// they left minimised, which is most of them when nobody is at the machine.
List<MinimisedWindow> enumerateMinimisedWindows() {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
    return const [];
  }
  final found = <MinimisedWindow>[];
  _enumAccumulator = found;
  try {
    _enumWindows(
      Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(
        _collectMinimised,
        1,
      ),
      0,
    );
  } finally {
    _enumAccumulator = [];
  }
  return found;
}

/// Makes [hwnd] the foreground window — restoring it first if it is minimised —
/// so a capture can select it, reporting whether it actually got there.
///
/// Shares [_raiseOffThread] with remote input rather than merely calling
/// `ShowWindow`: an owner-drawn or unresponsive window needs the same
/// foreground-lock workaround, and duplicating that would fork the one blast
/// site this file exists to keep singular.
Future<bool> focusWindowForCapture(int hwnd) async {
  if (!isLiveWindow(hwnd)) return false;
  return _raiseOffThread(hwnd);
}

int _processIdOf(int hwnd) {
  final pid = calloc<Uint32>();
  try {
    _getWindowThreadProcessId(hwnd, pid);
    return pid.value;
  } finally {
    calloc.free(pid);
  }
}

int _threadIdOf(int hwnd) {
  final pid = calloc<Uint32>();
  try {
    return _getWindowThreadProcessId(hwnd, pid);
  } finally {
    calloc.free(pid);
  }
}

/// Mandatory integrity level of [pid], or null when it cannot be read.
int? _integrityLevelOf(int pid) {
  final process = _openProcess(_processQueryLimitedInformation, 0, pid);
  if (process == 0) return null;
  final token = calloc<IntPtr>();
  final needed = calloc<Uint32>();
  Pointer<Uint8> label = nullptr;
  try {
    if (_openProcessToken(process, _tokenQuery, token) == 0) return null;
    _getTokenInformation(token.value, _tokenIntegrityLevel, nullptr, 0, needed);
    if (needed.value == 0) return null;
    label = calloc<Uint8>(needed.value);
    final ok = _getTokenInformation(
      token.value,
      _tokenIntegrityLevel,
      label,
      needed.value,
      needed,
    );
    if (ok == 0) return null;
    // TOKEN_MANDATORY_LABEL is a SID_AND_ATTRIBUTES, so the PSID is its first
    // pointer-sized field; the level is the SID's last sub-authority.
    final sid = label.cast<Pointer<Void>>().value;
    final count = _getSidSubAuthorityCount(sid);
    if (count == nullptr || count.value == 0) return null;
    return _getSidSubAuthority(sid, count.value - 1).value;
  } finally {
    if (label != nullptr) calloc.free(label);
    if (token.value != 0) _closeHandle(token.value);
    calloc.free(needed);
    calloc.free(token);
    _closeHandle(process);
  }
}

/// Whether [hwnd] belongs to a process UIPI will not let us drive.
///
/// Fails open when either integrity level is unreadable: a false "elevated"
/// verdict would block a session that would in fact have worked, and the real
/// failure is loud enough — nothing happens — to diagnose from the other end.
bool _targetOutranksUs(int hwnd) {
  final theirs = _integrityLevelOf(_processIdOf(hwnd));
  if (theirs == null) return false;
  final ours = _integrityLevelOf(_getCurrentProcessId());
  if (ours == null) return false;
  return theirs > ours;
}

// --- the foreground-lock workaround ----------------------------------------

/// The single blast site for the foreground-lock workaround.
///
/// A process without foreground rights cannot raise a window unless it shares
/// an input queue with the current foreground thread — bare
/// `SetForegroundWindow` from the background returns false immediately, and
/// `AttachThreadInput` is the documented-but-unsanctioned escape. Microsoft has
/// narrowed this before, so it lives in exactly one function: if a Windows
/// update breaks remote control, this is the only thing to re-measure.
///
/// Blocking, and called only from a worker isolate — see [_raiseOffThread].
bool _raiseBlocking(int hwnd) {
  if (_isIconic(hwnd) != 0) _showWindow(hwnd, _swRestore);
  if (_setForegroundWindow(hwnd) != 0 && _getForegroundWindow() == hwnd) {
    return true;
  }
  final foregroundThread = _threadIdOf(_getForegroundWindow());
  final ourThread = _getCurrentThreadId();
  final targetThread = _threadIdOf(hwnd);
  _attachThreadInput(ourThread, foregroundThread, 1);
  _attachThreadInput(targetThread, foregroundThread, 1);
  _bringWindowToTop(hwnd);
  _setForegroundWindow(hwnd);
  _attachThreadInput(targetThread, foregroundThread, 0);
  _attachThreadInput(ourThread, foregroundThread, 0);
  return _getForegroundWindow() == hwnd;
}

/// Attaching input queues couples this thread to the target's: if the target
/// stops pumping messages the call blocks for as long as it takes, and on the
/// UI isolate that is a frozen Antgrid. The worker isolate absorbs that instead.
///
/// A timeout abandons the isolate rather than killing it — a thread parked
/// inside a Win32 call cannot be interrupted from Dart. That leaks at most one
/// isolate per raise attempt, which is bounded by the once-per-session rule and
/// is strictly better than hanging the app.
Future<bool> _raiseOffThread(int hwnd) async {
  try {
    return await Isolate.run(() => _raiseBlocking(hwnd)).timeout(_raiseTimeout);
  } on TimeoutException {
    AbLog.warn(
      _component,
      'foreground raise timed out',
      fields: {'hwnd': hwnd},
    );
    return false;
  }
}

const Duration _raiseTimeout = Duration(seconds: 2);

// --- coordinate normalisation ----------------------------------------------

/// `SendInput` absolute coordinates are normalised to 0..65535 across the whole
/// virtual desktop, whose origin is negative when a monitor sits left of or
/// above the primary one.
@visibleForTesting
({int dx, int dy}) normalizeToVirtualDesktop(
  int screenX,
  int screenY, {
  required int originX,
  required int originY,
  required int width,
  required int height,
}) {
  final spanX = width > 1 ? width - 1 : 1;
  final spanY = height > 1 ? height - 1 : 1;
  return (
    dx: ((screenX - originX) * 65535 / spanX).round(),
    dy: ((screenY - originY) * 65535 / spanY).round(),
  );
}

// --- injector --------------------------------------------------------------

class Win32InputInjector implements InputInjector {
  Win32InputInjector() {
    assert(
      sizeOf<_MouseInput>() == 40 && sizeOf<_KeybdInput>() == 40,
      'INPUT must be 40 bytes; SendInput silently rejects a mismatched cbSize',
    );
  }

  int _target = 0;
  int _previousForeground = 0;
  FrameToScreenTransform? _transform;

  @override
  bool get isActive => _target != 0;

  @override
  Future<void> beginSession({
    required int targetWindowId,
    required FrameToScreenTransform transform,
  }) async {
    if (!isLiveWindow(targetWindowId)) {
      throw const InputInjectionException(
        InputInjectionFailure.targetGone,
        'That window has closed.',
      );
    }
    if (_targetOutranksUs(targetWindowId)) {
      throw const InputInjectionException(
        InputInjectionFailure.targetElevated,
        'That app runs as administrator. Windows blocks input from Antgrid '
        'into elevated apps, and no setting can change it.',
      );
    }

    _previousForeground = _getForegroundWindow();
    if (!await _raiseOffThread(targetWindowId)) {
      if (_isIconic(targetWindowId) != 0) {
        throw const InputInjectionException(
          InputInjectionFailure.targetMinimised,
          'That window is minimised. Restore it to control it remotely.',
        );
      }
      throw const InputInjectionException(
        InputInjectionFailure.foregroundDenied,
        'Windows would not bring that window to the front.',
      );
    }

    _target = targetWindowId;
    _transform = transform;
    AbLog.info(
      _component,
      'control session started',
      fields: {'hwnd': targetWindowId},
    );
  }

  @override
  void updateTransform(FrameToScreenTransform transform) {
    _transform = transform;
  }

  @override
  bool get targetIsForeground {
    if (_target == 0) return false;
    final foreground = _getForegroundWindow();
    if (foreground == 0) return false;
    // A framework may hand the foreground to a child or owned popup of the
    // captured window (Flutter's FLUTTERVIEW, WinUI's content bridge); those
    // still root at the target and are still the app the user picked.
    return foreground == _target ||
        _getAncestor(foreground, _gaRoot) == _target;
  }

  @override
  Future<bool> ensureForeground() async {
    if (_target == 0) return false;
    if (targetIsForeground) return true;
    if (!isLiveWindow(_target)) return false;
    return _raiseOffThread(_target);
  }

  @override
  Future<void> endSession() async {
    final target = _target;
    _target = 0;
    _transform = null;
    if (target == 0) return;
    AbLog.info(_component, 'control session ended', fields: {'hwnd': target});
    // Give the desktop back only if we still hold it. If the local user already
    // moved on, yanking their window away would be a second focus steal.
    final previous = _previousForeground;
    _previousForeground = 0;
    if (previous == 0 || previous == target) return;
    if (_getForegroundWindow() != target) return;
    if (!isLiveWindow(previous)) return;
    await _raiseOffThread(previous);
  }

  @override
  bool injectPointer(PointerInput event) {
    final point = _transform?.toScreen(event.frameX, event.frameY);
    if (point == null) return false;
    final flags = switch (event.action) {
      PointerAction.move => _mouseEventMove,
      PointerAction.down => _mouseEventMove | _downFlag(event.button),
      PointerAction.up => _mouseEventMove | _upFlag(event.button),
    };
    return _sendMouse([(x: point.x, y: point.y, flags: flags, data: 0)]);
  }

  @override
  bool injectScroll(ScrollInput event) {
    final point = _transform?.toScreen(event.frameX, event.frameY);
    if (point == null) return false;
    final batch = <({int x, int y, int flags, int data})>[];
    if (event.deltaY != 0) {
      batch.add((
        x: point.x,
        y: point.y,
        flags: _mouseEventMove | _mouseEventWheel,
        data: (event.deltaY * _wheelDelta).round(),
      ));
    }
    if (event.deltaX != 0) {
      batch.add((
        x: point.x,
        y: point.y,
        flags: _mouseEventMove | _mouseEventHWheel,
        data: (event.deltaX * _wheelDelta).round(),
      ));
    }
    if (batch.isEmpty) return false;
    return _sendMouse(batch);
  }

  @override
  bool injectKey(KeyInput event) {
    if (!_readyToSend()) return false;
    final buffer = calloc<_KeybdInput>();
    try {
      buffer.ref
        ..type = _inputKeyboard
        ..wVk = event.virtualKeyCode
        ..wScan = 0
        ..dwFlags =
            (event.down ? 0 : _keyEventKeyUp) |
            (isExtendedVirtualKey(event.virtualKeyCode) ? _keyEventExtended : 0)
        ..time = 0
        ..dwExtraInfo = 0;
      return _flush(1, buffer, sizeOf<_KeybdInput>());
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  bool injectText(String text) {
    if (text.isEmpty) return false;
    if (!_readyToSend()) return false;
    // Unicode scancodes bypass keyboard-layout translation, so the remote peer
    // types what they see regardless of the layout active on this machine.
    final units = Uint16List.fromList(text.codeUnits);
    final count = units.length * 2;
    final buffer = calloc<_KeybdInput>(count);
    try {
      for (var i = 0; i < units.length; i++) {
        for (var up = 0; up < 2; up++) {
          buffer[i * 2 + up]
            ..type = _inputKeyboard
            ..wVk = 0
            ..wScan = units[i]
            ..dwFlags = _keyEventUnicode | (up == 1 ? _keyEventKeyUp : 0)
            ..time = 0
            ..dwExtraInfo = 0;
        }
      }
      return _flush(count, buffer, sizeOf<_KeybdInput>());
    } finally {
      calloc.free(buffer);
    }
  }

  bool _sendMouse(List<({int x, int y, int flags, int data})> events) {
    if (!_readyToSend()) return false;
    final buffer = calloc<_MouseInput>(events.length);
    try {
      final originX = _getSystemMetrics(_smXVirtualScreen);
      final originY = _getSystemMetrics(_smYVirtualScreen);
      final width = _getSystemMetrics(_smCxVirtualScreen);
      final height = _getSystemMetrics(_smCyVirtualScreen);
      for (var i = 0; i < events.length; i++) {
        final event = events[i];
        final normalized = normalizeToVirtualDesktop(
          event.x,
          event.y,
          originX: originX,
          originY: originY,
          width: width,
          height: height,
        );
        buffer[i]
          ..type = _inputMouse
          ..dx = normalized.dx
          ..dy = normalized.dy
          // A negative wheel delta rides in a DWORD as two's complement.
          ..mouseData = event.data & 0xFFFFFFFF
          ..dwFlags = event.flags | _mouseEventAbsolute | _mouseEventVirtualDesk
          ..time = 0
          ..dwExtraInfo = 0;
      }
      return _flush(events.length, buffer, sizeOf<_MouseInput>());
    } finally {
      calloc.free(buffer);
    }
  }

  /// `SendInput` is system-wide — it goes wherever the foreground is, not to a
  /// window handle. Checking before every batch is what stops a remote peer
  /// typing into the local user's real apps when focus moves.
  bool _readyToSend() {
    if (_target == 0) return false;
    if (!isLiveWindow(_target)) {
      AbLog.warn(
        _component,
        'target window vanished',
        fields: {'hwnd': _target},
      );
      _target = 0;
      return false;
    }
    return targetIsForeground;
  }

  bool _flush(int count, Pointer buffer, int stride) {
    final accepted = _sendInput(count, buffer, stride);
    if (accepted == count) return true;
    // A short batch with the target in the foreground means UIPI ate it, which
    // beginSession should already have caught — log it rather than guess.
    AbLog.warn(
      _component,
      'SendInput batch rejected',
      fields: {'hwnd': _target, 'sent': accepted, 'expected': count},
    );
    return false;
  }
}

int _downFlag(PointerButton button) => switch (button) {
  PointerButton.left => _mouseEventLeftDown,
  PointerButton.right => _mouseEventRightDown,
  PointerButton.middle => _mouseEventMiddleDown,
};

int _upFlag(PointerButton button) => switch (button) {
  PointerButton.left => _mouseEventLeftUp,
  PointerButton.right => _mouseEventRightUp,
  PointerButton.middle => _mouseEventMiddleUp,
};
