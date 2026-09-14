// A local transport's post-ready teardown (see LocalTransport.onDone) has no
// other consumer in the app — this pins the provider that surfaces it and the
// fold that lets it take over the blocking error screen like any other
// transport error.
import 'package:antgrid/providers/local_transport_fault.dart';
import 'package:antgrid/screens/workspace_shell.dart'
    show workspaceBlockingError;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts null for a project nothing has faulted', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(localTransportFaultProvider('p1')), isNull);
  });

  test('set stores the fault, scoped per projectId', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(localTransportFaultProvider('p1').notifier)
        .set(const LocalTransportFault(closeCode: 4409, message: 'taken over'));

    expect(container.read(localTransportFaultProvider('p1'))?.closeCode, 4409);
    // A different project's family entry is untouched.
    expect(container.read(localTransportFaultProvider('p2')), isNull);
  });

  test('clear resets to null — what Retry must do before invalidating', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(localTransportFaultProvider('p1').notifier);
    notifier.set(
      const LocalTransportFault(closeCode: null, message: 'dropped'),
    );

    notifier.clear();

    expect(container.read(localTransportFaultProvider('p1')), isNull);
  });

  test('toString reads as a sentence — the blocking screen renders it '
      'verbatim', () {
    const fault = LocalTransportFault(
      closeCode: 4409,
      message: 'Another Antgrid window took over this project.',
    );

    expect(fault.toString(), 'Another Antgrid window took over this project.');
  });

  test('a set fault makes workspaceBlockingError non-null, ranked like any '
      'other transport error', () {
    const fault = LocalTransportFault(
      closeCode: null,
      message: 'The connection to the local bridge dropped.',
    );

    // workspace_shell folds the fault into `transportError` at the call site
    // (transportAsync.error ?? localFault) before handing it to this pure
    // function — exercised here directly per the ranking the function itself
    // owns, without pumping the whole shell widget.
    final error = workspaceBlockingError(
      transportError: fault,
      sessionError: null,
      liveStatus: null,
    );

    expect(error, same(fault));
  });
}
