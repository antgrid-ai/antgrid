import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const List<String> _items = <String>[
  'Terminal',
  'File explorer',
  'Git changes',
  'Browser preview',
  'Port forwarding',
  'Session history',
  'Scheduler',
  'Memory',
];

Widget _cell(Widget field) => SizedBox(width: 280, child: field);

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _query = TextEditingController();
  late final TextEditingController _filled = TextEditingController(
    text: 'preview',
  );
  late final TextEditingController _locked = TextEditingController(
    text: 'locked',
  );
  late final Map<CarbonFieldSize, TextEditingController> _sized =
      <CarbonFieldSize, TextEditingController>{
        for (final size in CarbonFieldSize.values)
          size: TextEditingController(text: size.name),
      };
  bool _busy = false;
  String _submitted = '';

  List<String> get _matches {
    final q = _query.text.trim().toLowerCase();
    return q.isEmpty
        ? _items
        : _items.where((i) => i.toLowerCase().contains(q)).toList();
  }

  @override
  void dispose() {
    _query.dispose();
    _filled.dispose();
    _locked.dispose();
    for (final controller in _sized.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final matches = _matches;
    return GalleryPage(
      title: 'Search',
      summary:
          'A search field with a clear action. It never debounces or '
          'fetches: the host owns the query, results, busy flag and error.',
      children: <Widget>[
        GallerySection(
          title: 'Filtering example',
          description:
              'The host filters a list on every change and feeds back the '
              'count. Toggle busy to see the spinner replace the icon.',
          children: <Widget>[
            CarbonSearch(
              controller: _query,
              busy: _busy,
              resultCount: matches.length,
              onChanged: (_) => setState(() {}),
              onSubmitted: (value) => setState(() => _submitted = value),
            ),
            const SizedBox(height: CarbonSpacing.spacing04),
            for (final item in matches)
              Text(
                item,
                style: theme.typography.body.copyWith(
                  color: theme.colors.textPrimary,
                ),
              ),
            if (matches.isEmpty)
              Text(
                CarbonLocalizations.of(context).noResults,
                style: theme.typography.body.copyWith(
                  color: theme.colors.textSecondary,
                ),
              ),
            const SizedBox(height: CarbonSpacing.spacing04),
            Text(
              _submitted.isEmpty
                  ? 'Press Enter to submit.'
                  : 'Submitted: $_submitted',
              style: theme.typography.helper.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
            const SizedBox(height: CarbonSpacing.spacing04),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: CarbonButton(
                label: _busy ? 'Stop busy' : 'Start busy',
                kind: CarbonButtonKind.tertiary,
                onPressed: () => setState(() => _busy = !_busy),
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'States',
          children: <Widget>[
            GalleryStateGrid(
              cells: <GalleryStateCell>[
                GalleryStateCell('empty', _cell(const CarbonSearch())),
                GalleryStateCell(
                  'with text',
                  _cell(CarbonSearch(controller: _filled)),
                ),
                GalleryStateCell(
                  'busy',
                  _cell(const CarbonSearch(busy: true)),
                ),
                GalleryStateCell(
                  'result count',
                  _cell(const CarbonSearch(resultCount: 12)),
                ),
                GalleryStateCell(
                  'no results',
                  _cell(const CarbonSearch(resultCount: 0)),
                ),
                GalleryStateCell(
                  'error',
                  _cell(
                    const CarbonSearch(
                      errorText: 'Search is unavailable right now',
                    ),
                  ),
                ),
                GalleryStateCell(
                  'error + focused',
                  _cell(
                    const CarbonSearch(
                      autofocus: true,
                      errorText: 'Search is unavailable right now',
                    ),
                  ),
                ),
                GalleryStateCell(
                  'disabled',
                  _cell(const CarbonSearch(enabled: false)),
                ),
                GalleryStateCell(
                  'read-only',
                  _cell(
                    CarbonSearch(
                      controller: _locked,
                      readOnly: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Sizes',
          description:
              'Small, medium and large from the Carbon scale. Touch density '
              'never goes below 48.',
          children: <Widget>[
            GalleryStateGrid(
              cells: <GalleryStateCell>[
                for (final size in CarbonFieldSize.values)
                  GalleryStateCell(
                    size.name,
                    _cell(
                      CarbonSearch(
                        size: size,
                        controller: _sized[size],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Long and enlarged',
          children: <Widget>[
            const CarbonSearch(
              placeholder:
                  'Search every project, session, file and scheduled run by '
                  'name or description',
              resultCount: 1280,
              errorText: null,
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Filtering or finding within a list or the whole product. The '
              'host debounces and fetches; the field only reports changes.',
          keyboard:
              'Escape clears a non-empty query and keeps focus. With an empty '
              'field Escape is not consumed, so an enclosing popup or modal '
              'can close. Enter submits. Tab reaches the clear action.',
          accessibility:
              'Named "Search" by default. The clear action is "Clear search". '
              'Busy announces "Loading" once and the result count is a '
              'polite live region announced when it changes.',
          carbonReference: 'Search',
        ),
      ],
    );
  }
}
