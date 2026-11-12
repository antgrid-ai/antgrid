import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const List<String> _initialTags = ['Backend', 'Frontend', 'Infra', 'Docs'];

void _noop() {}

class TagPage extends StatefulWidget {
  const TagPage({super.key});

  @override
  State<TagPage> createState() => _TagPageState();
}

class _TagPageState extends State<TagPage> {
  final List<String> _removable = [..._initialTags];
  final Set<String> _selected = {'Open'};
  int _pressed = 0;

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Tag',
      summary:
          'Compact labels for categorising and filtering. Selection and '
          'removal are separate targets.',
      children: [
        GallerySection(
          title: 'Colors',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing03,
              runSpacing: CarbonSpacing.spacing03,
              children: [
                for (final color in CarbonTagColor.values)
                  CarbonTag(label: color.name, color: color),
                const CarbonTag(label: 'disabled', disabled: true),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Sizes and icon',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing03,
              runSpacing: CarbonSpacing.spacing03,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final size in CarbonTagSize.values)
                  CarbonTag(
                    label: size.name,
                    color: CarbonTagColor.teal,
                    size: size,
                  ),
                const CarbonTag(
                  label: 'With icon',
                  color: CarbonTagColor.purple,
                  icon: CarbonIcon(CarbonIcons.star),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Dismissible',
          description:
              'The remove target is 32px (compact) or 48px (touch) and takes '
              'space in layout.',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing02,
              runSpacing: CarbonSpacing.spacing02,
              children: [
                for (final label in _removable)
                  CarbonTag(
                    key: ValueKey(label),
                    label: label,
                    color: CarbonTagColor.blue,
                    onDismissed: () => setState(() => _removable.remove(label)),
                  ),
                if (_removable.isEmpty)
                  CarbonTag(
                    label: 'Restore tags',
                    color: CarbonTagColor.outline,
                    onPressed: () =>
                        setState(() => _removable.addAll(_initialTags)),
                  ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Selectable and operational',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing02,
              runSpacing: CarbonSpacing.spacing02,
              children: [
                for (final label in const ['Open', 'Closed', 'Draft'])
                  CarbonTag(
                    label: label,
                    color: CarbonTagColor.gray,
                    selected: _selected.contains(label),
                    onSelectedChanged: (on) => setState(
                      () => on ? _selected.add(label) : _selected.remove(label),
                    ),
                  ),
                CarbonTag(
                  label: 'Selected and removable',
                  color: CarbonTagColor.green,
                  selected: _selected.contains('Both'),
                  onSelectedChanged: (on) => setState(
                    () => on ? _selected.add('Both') : _selected.remove('Both'),
                  ),
                  onDismissed: _noop,
                ),
                CarbonTag(
                  label: 'Pressed $_pressed',
                  color: CarbonTagColor.cyan,
                  onPressed: () => setState(() => _pressed++),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Truncation and disabled',
          children: [
            const SizedBox(
              width: 180,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: CarbonTag(
                  label: 'A very long tag label that truncates',
                  color: CarbonTagColor.magenta,
                ),
              ),
            ),
            const SizedBox(
              width: 220,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: CarbonTag(
                  label: 'Long and removable tag label here',
                  color: CarbonTagColor.red,
                  onDismissed: _noop,
                ),
              ),
            ),
            const Align(
              alignment: AlignmentDirectional.centerStart,
              child: CarbonTag(
                label: 'Disabled removable',
                onDismissed: _noop,
                disabled: true,
              ),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Metadata and filters. Use a button for commands and a '
              'notification for status that needs attention.',
          keyboard:
              'Selectable and operational tags are one stop; the remove '
              'action is its own stop. Space or Enter activates.',
          accessibility:
              'The full label is always announced, even when truncated. '
              'Remove is named "Remove <label>". Selected tags show a check '
              'mark as well as the inverse fill.',
          carbonReference:
              'Tag: sm 18, md 24, lg 32 pill; read-only, dismissible, '
              'selectable and operational variants.',
        ),
      ],
    );
  }
}
