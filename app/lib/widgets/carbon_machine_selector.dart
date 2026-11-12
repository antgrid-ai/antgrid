import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// Header button that names the machine a Carbon surface is showing and opens
/// a radio menu to switch. Provider-free so Scheduler and Memory share it:
/// callers own the demo guard, the same-id no-op and their own `mounted`
/// check. Only valid under an `AbCarbonScope`.
class CarbonMachineSelector extends StatelessWidget {
  const CarbonMachineSelector({
    super.key,
    required this.machines,
    required this.currentId,
    required this.name,
    required this.connected,
    required this.wide,
    required this.onPicked,
  });

  final Map<String, String> machines;
  final String currentId;
  final String name;
  final bool connected;
  final bool wide;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    final dot = connected ? colors.supportSuccess : colors.iconSecondary;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: CarbonSpacing.spacing05 * (wide ? 15 : 9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected ? dot : null,
                border: connected ? null : Border.all(color: dot),
              ),
              child: const SizedBox.square(dimension: CarbonSpacing.spacing03),
            ),
          ),
          Flexible(
            child: CarbonMenuButton(
              kind: CarbonButtonKind.ghost,
              label: name,
              maxLines: 1,
              triggerSemanticLabel:
                  'Machine: $name${connected ? '' : ', offline'}, change',
              semanticLabel: 'Machines',
              entries: [
                CarbonMenuRadioGroup<String>(
                  value: currentId,
                  options: [
                    for (final e in machines.entries)
                      CarbonOption<String>(value: e.key, label: e.value),
                  ],
                  onChanged: onPicked,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
