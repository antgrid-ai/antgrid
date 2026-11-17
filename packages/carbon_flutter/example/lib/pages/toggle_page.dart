import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class TogglePage extends StatefulWidget {
  const TogglePage({super.key});

  @override
  State<TogglePage> createState() => _TogglePageState();
}

class _TogglePageState extends State<TogglePage> {
  bool _live = false;
  bool _small = true;
  bool _saved = true;
  bool _saving = false;

  // The host owns persistence: the toggle keeps showing the saved value until
  // the simulated save completes.
  void _requestSave(bool next) {
    setState(() => _saving = true);
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() {
        _saved = next;
        _saving = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Toggle',
      summary:
          'Switches a setting that applies immediately. It always shows the '
          'value the host passes; there is no optimistic flip.',
      children: [
        GallerySection(
          title: 'Sizes',
          children: [
            CarbonToggle(
              value: _live,
              labelText: 'Default (48x24)',
              onChanged: (v) => setState(() => _live = v),
            ),
            CarbonToggle(
              value: _small,
              small: true,
              labelText: 'Small (32x16)',
              onChanged: (v) => setState(() => _small = v),
            ),
          ],
        ),
        GallerySection(
          title: 'Label is a target',
          description:
              'A tap on the label toggles, and label and switch are one '
              'accessibility node.',
          children: [
            CarbonToggle(
              value: _live,
              labelText: 'Tap this label',
              onChanged: (v) => setState(() => _live = v),
            ),
          ],
        ),
        GallerySection(
          title: 'States',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'off',
                  CarbonToggle(
                    value: false,
                    labelText: 'Setting',
                    onChanged: (_) {},
                  ),
                ),
                GalleryStateCell(
                  'on',
                  CarbonToggle(
                    value: true,
                    labelText: 'Setting',
                    onChanged: (_) {},
                  ),
                ),
                const GalleryStateCell(
                  'disabled off',
                  CarbonToggle(
                    value: false,
                    labelText: 'Setting',
                    onChanged: null,
                  ),
                ),
                const GalleryStateCell(
                  'disabled on',
                  CarbonToggle(
                    value: true,
                    labelText: 'Setting',
                    onChanged: null,
                  ),
                ),
                GalleryStateCell(
                  'read-only on',
                  CarbonToggle(
                    value: true,
                    readOnly: true,
                    labelText: 'Setting',
                    onChanged: (_) {},
                  ),
                ),
                GalleryStateCell(
                  'busy',
                  CarbonToggle(
                    value: false,
                    busy: true,
                    labelText: 'Setting',
                    onChanged: (_) {},
                  ),
                ),
                GalleryStateCell(
                  'no state text',
                  CarbonToggle(
                    value: true,
                    hideStateText: true,
                    semanticLabel: 'Setting',
                    onChanged: (_) {},
                  ),
                ),
                GalleryStateCell(
                  'long label',
                  CarbonToggle(
                    value: true,
                    labelText:
                        'Apply this change to every project on every machine '
                        'signed in to this account',
                    onChanged: (_) {},
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Host-controlled save',
          description:
              'The request is sent, the toggle stays busy on the old value, '
              'and only the host flips it once the save succeeds.',
          children: [
            CarbonToggle(
              value: _saved,
              busy: _saving,
              labelText: 'Sync settings',
              onChanged: _requestSave,
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'A setting that takes effect the moment it changes. Use a '
              'checkbox when the choice is submitted later with a form.',
          keyboard: 'Tab to focus, Space or Enter toggles.',
          accessibility:
              'Announced as a switch with on/off state; the visible On/Off '
              'word means color is never the only cue. Busy is announced as '
              'Loading and blocks activation.',
          carbonReference:
              'Toggle: 48x24 track, small 32x16, handle slides in fast motion '
              '(skipped under reduced motion).',
        ),
      ],
    );
  }
}
