import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/utils/agent_focus_coordinator.dart';

void main() {
  test('focuses the newly viewed terminal and blurs the previous one', () {
    final log = <String>[];
    void Function(bool) sink(String id) => (focused) => log.add('$id:$focused');

    final c = AgentFocusCoordinator();
    final keyA = Object();
    final keyB = Object();

    c.setViewed(keyA, sink('a'));
    expect(log, ['a:true']);

    c.setViewed(keyB, sink('b'));
    expect(log, ['a:true', 'a:false', 'b:true']);
  });

  test('null view (app backgrounded / nothing on screen) blurs current', () {
    final log = <String>[];
    void Function(bool) sink(String id) => (focused) => log.add('$id:$focused');

    final c = AgentFocusCoordinator();
    final keyA = Object();

    c.setViewed(keyA, sink('a'));
    c.setViewed(null, null);
    expect(log, ['a:true', 'a:false']);
  });

  test('same key dedups even when the setter closure differs each call', () {
    // Mirrors production: the binder passes a fresh `controller.setFocused`
    // tear-off each recompute, but the controller (key) is stable. Keying on
    // the tear-off would refire here (JIT tear-off identity is unstable);
    // keying on the stable key must not.
    final log = <String>[];
    final keyA = Object();

    final c = AgentFocusCoordinator();
    c.setViewed(keyA, (focused) => log.add('a:$focused'));
    c.setViewed(keyA, (focused) => log.add('a:$focused')); // different closure, same key
    expect(log, ['a:true']);
  });
}
