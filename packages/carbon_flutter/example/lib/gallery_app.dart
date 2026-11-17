import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/cupertino.dart' show DefaultCupertinoLocalizations;
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';

import 'gallery_scaffold.dart';

/// Viewport width presets; [pixels] is null for "fill".
enum GalleryWidth {
  phone320('Phone 320', 320),
  phone390('Phone 390', 390),
  tablet768('Tablet 768', 768),
  desktop1280('Desktop 1280', 1280),
  fill('Fill', null);

  const GalleryWidth(this.label, this.pixels);

  final String label;
  final double? pixels;
}

/// Everything the settings bar controls. Held in one immutable value so a
/// change rebuilds in place rather than remounting any page.
@immutable
class GallerySettings {
  const GallerySettings({
    this.scheme = CarbonThemeScheme.white,
    this.density = CarbonDensity.compact,
    this.textScale = 1.0,
    this.direction = TextDirection.ltr,
    this.width = GalleryWidth.fill,
    this.reducedMotion = false,
  });

  final CarbonThemeScheme scheme;
  final CarbonDensity density;
  final double textScale;
  final TextDirection direction;
  final GalleryWidth width;
  final bool reducedMotion;

  GallerySettings copyWith({
    CarbonThemeScheme? scheme,
    CarbonDensity? density,
    double? textScale,
    TextDirection? direction,
    GalleryWidth? width,
    bool? reducedMotion,
  }) => GallerySettings(
    scheme: scheme ?? this.scheme,
    density: density ?? this.density,
    textScale: textScale ?? this.textScale,
    direction: direction ?? this.direction,
    width: width ?? this.width,
    reducedMotion: reducedMotion ?? this.reducedMotion,
  );

  CarbonThemeData get theme => CarbonThemeData(scheme: scheme, density: density);

  /// Applies every setting to [child]. Used above the Navigator so pushed
  /// routes (modals, toasts) see the same text scale, direction, theme and
  /// motion as the previewed page; [width] additionally narrows the
  /// MediaQuery size for the preview viewport.
  Widget apply(BuildContext context, Widget child, {double? width}) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        size: width == null ? media.size : Size(width, media.size.height),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: reducedMotion,
      ),
      child: Directionality(
        textDirection: direction,
        child: CarbonTheme(data: theme, child: child),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GallerySettings &&
      other.scheme == scheme &&
      other.density == density &&
      other.textScale == textScale &&
      other.direction == direction &&
      other.width == width &&
      other.reducedMotion == reducedMotion;

  @override
  int get hashCode =>
      Object.hash(scheme, density, textScale, direction, width, reducedMotion);
}

/// The standalone component gallery.
class GalleryApp extends StatefulWidget {
  const GalleryApp({super.key});

  @override
  State<GalleryApp> createState() => _GalleryAppState();
}

class _GalleryAppState extends State<GalleryApp> {
  final ValueNotifier<GallerySettings> _settings =
      ValueNotifier<GallerySettings>(const GallerySettings());

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      title: 'carbon_flutter gallery',
      color: const Color(0xFF161616),
      debugShowCheckedModeBanner: false,
      localizationsDelegates: <LocalizationsDelegate<dynamic>>[
        DefaultWidgetsLocalizations.delegate,
        DefaultMaterialLocalizations.delegate,
        DefaultCupertinoLocalizations.delegate,
        CarbonLocalizations.delegate,
      ],
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, _, _) => builder(context),
          ),
      builder: (context, navigator) => ValueListenableBuilder<GallerySettings>(
        valueListenable: _settings,
        child: navigator,
        builder: (context, settings, navigator) =>
            settings.apply(context, navigator!),
      ),
      home: GalleryShell(settings: _settings),
    );
  }
}
