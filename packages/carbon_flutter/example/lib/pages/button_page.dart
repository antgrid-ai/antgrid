import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const String _longLabel = 'Save all changes to the project and close this panel';

class ButtonPage extends StatelessWidget {
  const ButtonPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Button',
      summary:
          'Actions in seven treatments. Height follows density, labels wrap '
          'under large text, and a busy button keeps its size and cannot be '
          'activated again.',
      children: [
        GallerySection(
          title: 'Kinds',
          description: 'Enabled, disabled and busy for every treatment.',
          children: [
            for (final kind in CarbonButtonKind.values)
              GalleryStateGrid(
                cells: [
                  GalleryStateCell(
                    kind.name,
                    CarbonButton(label: 'Action', kind: kind, onPressed: () {}),
                  ),
                  GalleryStateCell(
                    'with icon',
                    CarbonButton(
                      label: 'Add item',
                      kind: kind,
                      icon: const CarbonIcon(CarbonIcons.add),
                      onPressed: () {},
                    ),
                  ),
                  GalleryStateCell(
                    'disabled',
                    CarbonButton(label: 'Action', kind: kind),
                  ),
                  GalleryStateCell(
                    'busy',
                    CarbonButton(
                      label: 'Action',
                      kind: kind,
                      busy: true,
                      onPressed: () {},
                    ),
                  ),
                  GalleryStateCell(
                    'busy with icon',
                    CarbonButton(
                      label: 'Add item',
                      kind: kind,
                      busy: true,
                      icon: const CarbonIcon(CarbonIcons.add),
                      onPressed: () {},
                    ),
                  ),
                ],
              ),
          ],
        ),
        GallerySection(
          title: 'Sizes',
          description:
              'Explicit heights from the Carbon scale. Touch density never '
              'goes below 48.',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'default',
                  CarbonButton(label: 'Default', onPressed: () {}),
                ),
                for (final size in CarbonButtonSize.values)
                  GalleryStateCell(
                    size.name,
                    CarbonButton(
                      label: size.name,
                      size: size,
                      onPressed: () {},
                    ),
                  ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Icon only',
          description: 'Square footprint; the semantic label names it.',
          children: [
            GalleryStateGrid(
              cells: [
                for (final kind in [
                  CarbonButtonKind.primary,
                  CarbonButtonKind.secondary,
                  CarbonButtonKind.tertiary,
                  CarbonButtonKind.ghost,
                  CarbonButtonKind.danger,
                ])
                  GalleryStateCell(
                    kind.name,
                    CarbonButton.iconOnly(
                      icon: const CarbonIcon(CarbonIcons.trashCan),
                      semanticLabel: 'Delete',
                      kind: kind,
                      onPressed: () {},
                    ),
                  ),
                const GalleryStateCell(
                  'disabled',
                  CarbonButton.iconOnly(
                    icon: CarbonIcon(CarbonIcons.settings),
                    semanticLabel: 'Settings',
                  ),
                ),
                GalleryStateCell(
                  'busy',
                  CarbonButton.iconOnly(
                    icon: const CarbonIcon(CarbonIcons.settings),
                    semanticLabel: 'Settings',
                    busy: true,
                    onPressed: () {},
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Long labels and expansion',
          description:
              'Labels wrap and the button grows. Expanded buttons put the '
              'icon at the end edge in either direction.',
          children: [
            CarbonButton(
              label: _longLabel,
              icon: const CarbonIcon(CarbonIcons.arrowRight),
              onPressed: () {},
            ),
            CarbonButton(
              label: _longLabel,
              icon: const CarbonIcon(CarbonIcons.arrowRight),
              busy: true,
              onPressed: () {},
            ),
            CarbonButton(
              label: 'Continue',
              icon: const CarbonIcon(CarbonIcons.arrowRight),
              expand: true,
              onPressed: () {},
            ),
            CarbonButton(
              label: 'Continue',
              kind: CarbonButtonKind.tertiary,
              expand: true,
              onPressed: () {},
            ),
          ],
        ),
        const GallerySection(
          title: 'Host-owned busy',
          description:
              'The host decides when work starts and ends. While busy the '
              'button swallows taps and keeps focus.',
          children: [_BusyDemo()],
        ),
        GallerySection(
          title: 'Button set',
          description:
              'Modal and form footers. The set stacks, primary on top, '
              'when labels no longer fit.',
          children: [
            CarbonButtonSet(
              children: [
                CarbonButton(
                  label: 'Cancel',
                  kind: CarbonButtonKind.secondary,
                  onPressed: () {},
                ),
                CarbonButton(label: 'Save', onPressed: () {}),
              ],
            ),
            CarbonButtonSet(
              alignment: CarbonButtonSetAlignment.fill,
              children: [
                CarbonButton(
                  label: 'Cancel',
                  kind: CarbonButtonKind.secondary,
                  onPressed: () {},
                ),
                CarbonButton(
                  label: 'Delete project',
                  kind: CarbonButtonKind.danger,
                  onPressed: () {},
                ),
              ],
            ),
            SizedBox(
              width: 180,
              child: CarbonButtonSet(
                alignment: CarbonButtonSetAlignment.fill,
                children: [
                  CarbonButton(
                    label: 'Cancel',
                    kind: CarbonButtonKind.secondary,
                    onPressed: () {},
                  ),
                  CarbonButton(label: 'Save changes', onPressed: () {}),
                ],
              ),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Primary for the one main action, secondary or tertiary for '
              'alternatives, ghost for low-emphasis actions, danger for '
              'destructive ones. Use an icon-only button only where the '
              'icon is unambiguous.',
          keyboard:
              'Tab to focus, Enter or Space to activate once. Disabled '
              'buttons leave the tab order; busy buttons keep focus.',
          accessibility:
              'Icon-only buttons need a semantic label. Busy is announced '
              'as the localized "Loading" value. Disabled and busy are '
              'never conveyed by color alone.',
          carbonReference:
              'Carbon v11 Button and Button set. Deviations: height follows '
              'the 32/48 density instead of the 48px Carbon default; end '
              'padding is a symmetric 16px, not the 64px reserved for the '
              'icon; busy is added and has no Carbon equivalent; a button '
              'set stacks when its labels do not fit; icon-only buttons '
              'show their name in a tooltip.',
        ),
      ],
    );
  }
}

class _BusyDemo extends StatefulWidget {
  const _BusyDemo();

  @override
  State<_BusyDemo> createState() => _BusyDemoState();
}

class _BusyDemoState extends State<_BusyDemo> {
  bool _busy = false;
  int _submits = 0;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Wrap(
      spacing: CarbonSpacing.spacing04,
      runSpacing: CarbonSpacing.spacing03,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        CarbonButton(
          label: 'Submit',
          busy: _busy,
          onPressed: () => setState(() => _submits++),
        ),
        CarbonButton(
          label: _busy ? 'Finish work' : 'Start work',
          kind: CarbonButtonKind.tertiary,
          onPressed: () => setState(() => _busy = !_busy),
        ),
        Text(
          'Submitted $_submits times',
          style: theme.typography.body.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
      ],
    );
  }
}
