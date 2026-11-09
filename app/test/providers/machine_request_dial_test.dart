import 'dart:async';

import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/providers/scheduler.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderContainer _neverDials() {
  final c = ProviderContainer(
    overrides: [
      controlPlaneClientForProvider.overrideWith(
        (ref, uuid) => Completer<ControlPlaneClient?>().future,
      ),
      schedulerTargetProvider.overrideWithValue('m1'),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('Scheduler gives up on a machine that never connects', () {
    fakeAsync((async) {
      final c = _neverDials();
      Object? error;
      c.read(schedulerRequestProvider)('scheduler.list').catchError((Object e) {
        error = e;
        return <String, dynamic>{};
      });

      async.elapse(
        kMachineRequestDialWait - const Duration(milliseconds: 1),
      );
      expect(error, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(
        error,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Machine unavailable. Connect it to manage schedules.',
        ),
      );
    });
  });

  test('Memory gives up on a machine that never connects', () {
    fakeAsync((async) {
      final c = _neverDials();
      Object? error;
      c
          .read(memoryRequestProvider(const MemoryTarget.machine(machineId: 'm1')))(
            {'op': 'status'},
          )
          .catchError((Object e) {
            error = e;
            return <String, dynamic>{};
          });

      async.elapse(kMachineRequestDialWait);
      expect(
        error,
        isA<MemoryException>().having((e) => e.code, 'code', 'NOT_CONNECTED'),
      );
    });
  });
}
