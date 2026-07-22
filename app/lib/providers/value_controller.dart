import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Minimal settable-value [Notifier] — the idiomatic Riverpod 3 replacement for
/// the legacy `StateProvider<T>` (a value with a public setter). Reach for a
/// named, purpose-built Notifier when the value carries domain logic; this is
/// only for the ephemeral UI state `StateProvider` used to hold.
class ValueController<T> extends Notifier<T> {
  ValueController(this._initial);
  final T _initial;

  @override
  T build() => _initial;

  void set(T value) => state = value;
}
