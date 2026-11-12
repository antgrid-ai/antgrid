import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class InlineLoadingPage extends StatefulWidget {
  const InlineLoadingPage({super.key});

  @override
  State<InlineLoadingPage> createState() => _InlineLoadingPageState();
}

class _InlineLoadingPageState extends State<InlineLoadingPage> {
  CarbonInlineLoadingStatus _status = CarbonInlineLoadingStatus.inactive;
  int _retries = 0;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Inline loading',
      summary:
          'Compact pending, success and failure feedback beside an action. '
          'The host owns the status and any timing.',
      children: [
        const GallerySection(
          title: 'Statuses',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'inactive',
                  CarbonInlineLoading(
                    status: CarbonInlineLoadingStatus.inactive,
                    description: 'Idle',
                  ),
                ),
                GalleryStateCell(
                  'active',
                  CarbonInlineLoading(
                    status: CarbonInlineLoadingStatus.active,
                    description: 'Saving...',
                  ),
                ),
                GalleryStateCell(
                  'finished',
                  CarbonInlineLoading(
                    status: CarbonInlineLoadingStatus.finished,
                    description: 'Saved',
                  ),
                ),
                GalleryStateCell(
                  'error',
                  CarbonInlineLoading(
                    status: CarbonInlineLoadingStatus.error,
                    description: 'Save failed',
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Retry and long descriptions',
          description:
              'Retry is an explicit action. Long text wraps with the '
              'indicator on the first line.',
          children: [
            CarbonInlineLoading(
              status: CarbonInlineLoadingStatus.error,
              description:
                  'Could not save the project because the connection to '
                  'your machine dropped',
              onRetry: () => setState(() => _retries++),
            ),
            Text(
              'Retry pressed $_retries times',
              style: theme.typography.helper.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
            const CarbonInlineLoading(
              status: CarbonInlineLoadingStatus.active,
              description:
                  'Synchronizing a very large number of files across all '
                  'of your connected machines',
            ),
          ],
        ),
        GallerySection(
          title: 'Beside an action',
          description: 'Host-driven: pick a status as the work would.',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing04,
              runSpacing: CarbonSpacing.spacing03,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CarbonButton(
                  label: 'Save',
                  busy: _status == CarbonInlineLoadingStatus.active,
                  onPressed: () =>
                      setState(() => _status = CarbonInlineLoadingStatus.active),
                ),
                CarbonInlineLoading(
                  status: _status,
                  description: switch (_status) {
                    CarbonInlineLoadingStatus.inactive => 'Not saved',
                    CarbonInlineLoadingStatus.active => 'Saving...',
                    CarbonInlineLoadingStatus.finished => 'Saved',
                    CarbonInlineLoadingStatus.error => 'Save failed',
                  },
                  onRetry: () =>
                      setState(() => _status = CarbonInlineLoadingStatus.active),
                ),
              ],
            ),
            Wrap(
              spacing: CarbonSpacing.spacing03,
              runSpacing: CarbonSpacing.spacing03,
              children: [
                for (final s in CarbonInlineLoadingStatus.values)
                  CarbonButton(
                    label: s.name,
                    kind: CarbonButtonKind.ghost,
                    size: CarbonButtonSize.small,
                    onPressed: () => setState(() => _status = s),
                  ),
              ],
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Feedback for a single action or control, such as saving or '
              'testing a connection. Use Loading for a whole region.',
          keyboard:
              'The indicator is not focusable; the optional Retry button '
              'is a normal button.',
          accessibility:
              'A polite live region announces each status change once '
              '(description plus Loading, Success or Error). The spinner '
              'frames are not announced. Status is never color alone.',
          carbonReference: 'Carbon v11 Inline loading.',
        ),
      ],
    );
  }
}
