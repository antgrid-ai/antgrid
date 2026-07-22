/// Cross-platform pseudo-terminal (PTY) for Dart.
///
/// On native targets the PTY is backed by a Rust `portable-pty` shared
/// library. On web targets a browser-safe transport (WebSocket or
/// WebTransport) is used instead. Import this library for the
/// platform-resolved [PortablePty] API.
library;

/// Core [PortablePty] class and supporting types.
///
/// Resolves to the native FFI implementation on non-web targets and to
/// the browser transport wrapper on web targets.
export 'src/pty.dart' if (dart.library.js_interop) 'src/pty_web.dart';

/// Shared [PortablePtyTransport] contract consumed by both native and
/// web backends.
export 'src/pty_transport.dart';

/// Lightweight listener mixin used by [PortablePtyController].
///
/// Provides [addListener], [removeListener], and [notifyListeners]
/// without depending on Flutter's `ChangeNotifier`.
export 'src/pty_controller_base.dart';

/// Platform-resolved [PortablePtyController].
///
/// On native targets the controller spawns a local PTY subprocess.
/// On web targets it connects through a remote transport.
export 'src/pty_controller.dart';
