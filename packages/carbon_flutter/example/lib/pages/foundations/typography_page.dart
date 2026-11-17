import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

String _num(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

String _metrics(TextStyle s) {
  final size = s.fontSize ?? 0;
  final line = size * (s.height ?? 1);
  return '${_num(size)}/${_num(line)}px  w${s.fontWeight?.value ?? 400}  '
      'tracking ${_num(s.letterSpacing ?? 0)}  ${s.fontFamily}';
}

/// Each type role with its resolved metrics.
class TypographyPage extends StatelessWidget {
  const TypographyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final type = theme.typography;
    final roles = <(String, String, TextStyle)>[
      ('label', 'Field labels, tag text', type.label),
      ('helper', 'Helper and validation text', type.helper),
      ('control', 'Text inside single-line controls', type.control),
      ('body', 'Running text in modals and notifications', type.body),
      ('heading', 'Section and row headings', type.heading),
      ('headingLarge', 'Modal titles, larger section headings', type.headingLarge),
      ('title', 'Page-level headings', type.title),
      ('code', 'Identifiers, paths, ports: data, never chrome', type.code),
    ];
    return GalleryPage(
      title: 'Typography',
      summary:
          'Roles resolved for ${theme.density.name} density. Switch density '
          'above to compare the two sets; both use the bundled IBM Plex '
          'families.',
      children: [
        GallerySection(
          title: 'Roles',
          children: [
            for (final role in roles)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${role.$1}  ·  ${role.$2}',
                    style: type.label.copyWith(
                      color: theme.colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: CarbonSpacing.spacing02),
                  Text(
                    'The quick brown fox jumps over the lazy dog 0123456789',
                    style: role.$3.copyWith(color: theme.colors.textPrimary),
                  ),
                  const SizedBox(height: CarbonSpacing.spacing02),
                  Text(
                    _metrics(role.$3),
                    style: type.code.copyWith(color: theme.colors.textHelper),
                  ),
                ],
              ),
          ],
        ),
        GallerySection(
          title: 'Long unbroken content',
          description: 'Wraps at every width and text scale instead of clipping.',
          children: [
            Text(
              'Supercalifragilisticexpialidocious_and_a_very_long_identifier'
              '_that_has_no_break_points_at_all',
              style: type.code.copyWith(color: theme.colors.textPrimary),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Picking a role for new text; never set raw sizes in components.',
          keyboard: 'Not interactive.',
          accessibility:
              'Sizes follow the viewport text scale; line heights are sized '
              'so scaled text grows its container instead of overlapping.',
          carbonReference: 'Type sets: productive styles and the touch lift.',
        ),
      ],
    );
  }
}
