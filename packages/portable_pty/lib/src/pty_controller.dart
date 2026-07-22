/// Platform-conditional controller export.
///
/// On native targets (VM / AOT) this resolves to [PortablePtyController] from
/// `pty_controller_native.dart`, which uses `dart:io` for default-shell
/// resolution.  On web targets it resolves to the web variant which adds
/// error-resilient writes and endpoint fallback logic.
library;

export 'pty_controller_native.dart'
    if (dart.library.js_interop) 'pty_controller_web.dart';
