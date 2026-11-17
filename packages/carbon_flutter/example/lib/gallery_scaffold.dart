import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import 'gallery_app.dart';
import 'registry.dart';
import 'widgets/gallery_controls.dart';

/// Width at which the page list becomes a side column.
const double _kWideBreakpoint = 900;

/// The gallery's chrome keeps one dark theme so it stays readable whatever
/// theme, density or text scale the previewed viewport is set to.
final CarbonThemeData _chromeTheme = CarbonThemeData(
  scheme: CarbonThemeScheme.gray100,
);

/// Settings bar, page navigation and the themed preview viewport.
class GalleryShell extends StatefulWidget {
  const GalleryShell({super.key, required this.settings});

  final ValueNotifier<GallerySettings> settings;

  @override
  State<GalleryShell> createState() => _GalleryShellState();
}

class _GalleryShellState extends State<GalleryShell> {
  String _selectedId = galleryEntries.first.id;
  bool _settingsOpen = false;

  GalleryEntry get _entry =>
      galleryEntries.firstWhere((e) => e.id == _selectedId);

  void _update(GallerySettings Function(GallerySettings) change) {
    widget.settings.value = change(widget.settings.value);
  }

  @override
  Widget build(BuildContext context) {
    // The chrome opts out of the previewed text scale, direction and motion
    // (applied above the Navigator) so it stays operable at 200% or RTL.
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.noScaling,
        disableAnimations: false,
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: CarbonTheme(
          data: _chromeTheme,
          child: ColoredBox(
        color: _chromeTheme.colors.background,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _kWideBreakpoint;
            final viewport = Expanded(child: _buildViewport());
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 220, child: _buildSideList()),
                  Container(width: 1, color: _chromeTheme.colors.borderSubtle00),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(CarbonSpacing.spacing04),
                          child: _buildSettings(),
                        ),
                        viewport,
                      ],
                    ),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPageSelector(),
                _buildSettingsDisclosure(constraints.maxHeight),
                viewport,
              ],
            );
          },
        ),
          ),
        ),
      ),
    );
  }

  Widget _pageButton(GalleryEntry entry, {bool expand = false}) {
    final selected = entry.id == _selectedId;
    return Semantics(
      selected: selected,
      child: CarbonButton(
        key: ValueKey('page-${entry.id}'),
        label: entry.title,
        kind: selected ? CarbonButtonKind.primary : CarbonButtonKind.ghost,
        size: CarbonButtonSize.small,
        expand: expand,
        onPressed: () => setState(() => _selectedId = entry.id),
      ),
    );
  }

  Widget _buildSideList() {
    final type = _chromeTheme.typography;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(CarbonSpacing.spacing04),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('carbon_flutter', style: type.headingLarge),
          const SizedBox(height: CarbonSpacing.spacing05),
          for (final group in galleryGroups)
            ..._groupColumn(group, type),
        ],
      ),
    );
  }

  List<Widget> _groupColumn(String group, CarbonTypography type) {
    final entries = galleryEntries.where((e) => e.group == group).toList();
    if (entries.isEmpty) return const <Widget>[];
    return [
      Padding(
        padding: const EdgeInsets.only(
          top: CarbonSpacing.spacing03,
          bottom: CarbonSpacing.spacing02,
        ),
        child: Text(
          group,
          style: type.label.copyWith(color: _chromeTheme.colors.textSecondary),
        ),
      ),
      for (final entry in entries)
        Padding(
          padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing01),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: _pageButton(entry, expand: true),
          ),
        ),
    ];
  }

  Widget _buildPageSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(CarbonSpacing.spacing03),
      child: Row(
        children: [
          for (final entry in galleryEntries)
            Padding(
              padding: const EdgeInsetsDirectional.only(
                end: CarbonSpacing.spacing01,
              ),
              child: _pageButton(entry),
            ),
        ],
      ),
    );
  }

  Widget _buildSettingsDisclosure(double availableHeight) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: CarbonSpacing.spacing03,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Semantics(
              expanded: _settingsOpen,
              child: CarbonButton(
                key: const ValueKey('settings-toggle'),
                label: 'Settings',
                kind: _settingsOpen
                    ? CarbonButtonKind.primary
                    : CarbonButtonKind.tertiary,
                size: CarbonButtonSize.small,
                onPressed: () =>
                    setState(() => _settingsOpen = !_settingsOpen),
              ),
            ),
          ),
        ),
        if (_settingsOpen)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: availableHeight * 0.5),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(CarbonSpacing.spacing03),
              child: _buildSettings(),
            ),
          ),
        const SizedBox(height: CarbonSpacing.spacing03),
      ],
    );
  }

  Widget _buildSettings() {
    return ValueListenableBuilder<GallerySettings>(
      valueListenable: widget.settings,
      builder: (context, s, _) {
        return Wrap(
          spacing: CarbonSpacing.spacing06,
          runSpacing: CarbonSpacing.spacing04,
          children: [
            GallerySegmented<CarbonThemeScheme>(
              name: 'scheme',
              label: 'Theme',
              value: s.scheme,
              options: [
                for (final v in CarbonThemeScheme.values)
                  GalleryOption(v.name, v, v.name),
              ],
              onChanged: (v) => _update((c) => c.copyWith(scheme: v)),
            ),
            GallerySegmented<CarbonDensity>(
              name: 'density',
              label: 'Density',
              value: s.density,
              options: [
                for (final v in CarbonDensity.values)
                  GalleryOption(v.name, v, v.name),
              ],
              onChanged: (v) => _update((c) => c.copyWith(density: v)),
            ),
            GallerySegmented<double>(
              name: 'textScale',
              label: 'Text scale',
              value: s.textScale,
              options: const [
                GalleryOption('1.0', 1.0, '100%'),
                GalleryOption('1.5', 1.5, '150%'),
                GalleryOption('2.0', 2.0, '200%'),
              ],
              onChanged: (v) => _update((c) => c.copyWith(textScale: v)),
            ),
            GallerySegmented<TextDirection>(
              name: 'direction',
              label: 'Direction',
              value: s.direction,
              options: const [
                GalleryOption('ltr', TextDirection.ltr, 'LTR'),
                GalleryOption('rtl', TextDirection.rtl, 'RTL'),
              ],
              onChanged: (v) => _update((c) => c.copyWith(direction: v)),
            ),
            GallerySegmented<GalleryWidth>(
              name: 'width',
              label: 'Width',
              value: s.width,
              options: [
                for (final v in GalleryWidth.values)
                  GalleryOption(v.name, v, v.label),
              ],
              onChanged: (v) => _update((c) => c.copyWith(width: v)),
            ),
            GallerySegmented<bool>(
              name: 'motion',
              label: 'Reduced motion',
              value: s.reducedMotion,
              options: const [
                GalleryOption('off', false, 'Off'),
                GalleryOption('on', true, 'On'),
              ],
              onChanged: (v) => _update((c) => c.copyWith(reducedMotion: v)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildViewport() {
    return ValueListenableBuilder<GallerySettings>(
      valueListenable: widget.settings,
      builder: (context, s, _) {
        final entry = _entry;
        return ColoredBox(
          color: _chromeTheme.colors.layer01,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = math.min(
                s.width.pixels ?? constraints.maxWidth,
                constraints.maxWidth,
              );
              // Structure is identical for every setting so changing one
              // updates the page in place and its live state survives.
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: width,
                  height: constraints.maxHeight,
                  child: s.apply(
                    context,
                    width: width,
                    _PageViewport(
                      key: ValueKey(entry.id),
                      child: Builder(builder: entry.builder),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _PageViewport extends StatelessWidget {
  const _PageViewport({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return ColoredBox(
      color: theme.colors.background,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(CarbonSpacing.spacing05),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [child],
        ),
      ),
    );
  }
}

/// A page's title and summary followed by its sections.
class GalleryPage extends StatelessWidget {
  const GalleryPage({
    super.key,
    required this.title,
    required this.summary,
    required this.children,
  });

  final String title;
  final String summary;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.typography.title),
        ),
        const SizedBox(height: CarbonSpacing.spacing03),
        Text(
          summary,
          style: theme.typography.body.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
        const SizedBox(height: CarbonSpacing.spacing06),
        ...children,
      ],
    );
  }
}

/// A titled group of demos on a gallery page.
class GallerySection extends StatelessWidget {
  const GallerySection({
    super.key,
    required this.title,
    this.description,
    required this.children,
  });

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final description = this.description;
    return Padding(
      padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing07),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: theme.typography.headingLarge),
          ),
          if (description != null) ...[
            const SizedBox(height: CarbonSpacing.spacing02),
            Text(
              description,
              style: theme.typography.body.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: CarbonSpacing.spacing04),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: CarbonSpacing.spacing04),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Short guidance block: when to use a thing, how it is operated, how it is
/// announced, and where Carbon specifies it.
class GalleryNote extends StatelessWidget {
  const GalleryNote({
    super.key,
    required this.useWhen,
    required this.keyboard,
    required this.accessibility,
    required this.carbonReference,
  });

  final String useWhen;
  final String keyboard;
  final String accessibility;
  final String carbonReference;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    Widget row(String label, String text) => Padding(
      padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing03),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.typography.label.copyWith(
              color: theme.colors.textSecondary,
            ),
          ),
          Text(text, style: theme.typography.body),
        ],
      ),
    );
    return CarbonLayerSurface(
      border: true,
      padding: const EdgeInsets.fromLTRB(
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing02,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row('Use when', useWhen),
          row('Keyboard', keyboard),
          row('Accessibility', accessibility),
          row('Carbon reference', carbonReference),
        ],
      ),
    );
  }
}

/// One labelled state in a [GalleryStateGrid].
class GalleryStateCell {
  const GalleryStateCell(this.label, this.child);

  final String label;
  final Widget child;
}

/// Lays out labelled cells so state combinations can be scanned side by side.
class GalleryStateGrid extends StatelessWidget {
  const GalleryStateGrid({super.key, required this.cells});

  final List<GalleryStateCell> cells;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: CarbonSpacing.spacing06,
          runSpacing: CarbonSpacing.spacing05,
          children: [
            for (final cell in cells)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cell.label,
                      style: theme.typography.label.copyWith(
                        color: theme.colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: CarbonSpacing.spacing02),
                    cell.child,
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
