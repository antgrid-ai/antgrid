/// Lightweight listener mechanism for [PortablePtyController].
///
/// This replaces Flutter's `ChangeNotifier` so the controller can be used
/// from pure Dart (CLI, server, tests) without a Flutter dependency.
///
/// ```dart
/// class MyController with PtyListenable {
///   void doWork() {
///     // ... perform work ...
///     notifyListeners();
///   }
/// }
///
/// final controller = MyController();
/// controller.addListener(() => print('state changed'));
/// controller.doWork(); // prints 'state changed'
/// controller.dispose();
/// ```
mixin PtyListenable {
  final List<void Function()> _listeners = <void Function()>[];
  bool _disposed = false;

  /// Register a callback that fires whenever state changes.
  ///
  /// The [listener] will be called each time [notifyListeners] is invoked.
  /// Listeners added after [dispose] are silently ignored.
  void addListener(void Function() listener) {
    if (_disposed) return;
    _listeners.add(listener);
  }

  /// Remove a previously registered listener.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Notify all registered listeners of a state change.
  void notifyListeners() {
    if (_disposed) return;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// Whether this object has been disposed.
  bool get isDisposed => _disposed;

  /// Releases resources and prevents further notifications.
  ///
  /// After calling this, [isDisposed] returns `true` and
  /// [notifyListeners] becomes a no-op.
  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}
