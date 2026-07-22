import 'package:antgrid/project/fragment_recovery.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('re-requests file:content once per key, then reports failure', () {
    final reReq = <String>[];
    final diffReq = <String>[];
    final failed = <FragHint>[];
    final c = FragmentRecoveryCoordinator(
      requestFileContent: reReq.add,
      requestDiff: diffReq.add,
      onFailed: failed.add,
    );

    c.onAbort(const FragHint('file:content', 'a.png'));
    c.onAbort(const FragHint('file:content', 'a.png'));
    c.onAbort(const FragHint('file:content', 'a.png'));
    expect(reReq, ['a.png']);
    expect(failed.length, 2); // both over-cap aborts surface failure
    expect(diffReq, isEmpty);

    c.onSuccess(const FragHint('file:content', 'a.png'));
    c.onAbort(const FragHint('file:content', 'a.png'));
    expect(reReq, ['a.png', 'a.png']);
  });

  test('re-requests git:diff-content via requestDiff', () {
    final reReq = <String>[];
    final diffReq = <String>[];
    final failed = <FragHint>[];
    final c = FragmentRecoveryCoordinator(
      requestFileContent: reReq.add,
      requestDiff: diffReq.add,
      onFailed: failed.add,
    );

    c.onAbort(const FragHint('git:diff-content', 'a.dart'));
    expect(diffReq, ['a.dart']);
    expect(reReq, isEmpty);
    expect(failed, isEmpty);

    // file:content and git:diff-content track separate retry budgets per key.
    c.onAbort(const FragHint('git:diff-content', 'a.dart'));
    expect(diffReq, ['a.dart']);
    expect(failed.length, 1);
  });

  test('reports failure for hint types with no re-request mapping', () {
    final failed = <FragHint>[];
    final c = FragmentRecoveryCoordinator(
      requestFileContent: (_) {},
      requestDiff: (_) {},
      onFailed: failed.add,
    );
    c.onAbort(const FragHint('tree:full', 'x'));
    expect(failed.single.type, 'tree:full');
  });
}
