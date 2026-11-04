import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/widgets/project_sidebar.dart';
import 'package:flutter_test/flutter_test.dart';

MachineInfo _machine(String id, String name) =>
    MachineInfo(id: id, name: name, isLocal: false, online: true);

void main() {
  test('takes the initials of the first two words, splitting camel case', () {
    expect(shortMachineTag('MacBook Pro'), 'MB');
    expect(shortMachineTag('Linux Studio'), 'LS');
    expect(shortMachineTag('DESKTOP-4KQ2'), 'D4');
    expect(shortMachineTag('workstation'), 'WO');
    expect(shortMachineTag('x'), 'X');
    expect(shortMachineTag('  '), '?');
  });

  test('numbers machines whose tags would collide', () {
    final tags = machineShortTags([
      _machine('a', 'Mac Book'),
      _machine('b', 'MacBook Pro'),
      _machine('c', 'Linux Studio'),
    ]);
    expect(tags, {'a': 'M1', 'b': 'M2', 'c': 'LS'});
  });
}
