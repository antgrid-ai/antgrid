import 'package:flutter/material.dart';

/// Colours no Carbon token uses, so any of them in a paint call means the
/// host app's Material theme reached a Carbon component.
const Color hostBorder = Color(0xFFFF00FF);
const Color hostFocused = Color(0xFF00FFFF);
const Color hostFill = Color(0xFF00FF00);
const Color hostOverlay = Color(0xFFFF8000);
const Color hostSelection = Color(0xFF8000FF);
const Color hostText = Color(0xFFFFFF00);

final Set<Color> hostColors = {
  hostBorder,
  hostFocused,
  hostFill,
  hostOverlay,
  hostSelection,
  hostText,
};

/// A Material app theme of the kind a real host ships: outlined, filled
/// fields, ink overlays, a branded selection colour, scrollbar, tooltip, icon
/// and text themes. Carbon components draw their own states and must ignore
/// all of it.
final ThemeData hostileHostTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: hostOverlay).copyWith(
    primary: hostOverlay,
    secondary: hostOverlay,
    surface: hostFill,
    onSurface: hostText,
  ),
  splashColor: hostOverlay,
  highlightColor: hostOverlay,
  hoverColor: hostOverlay,
  focusColor: hostOverlay,
  textSelectionTheme: const TextSelectionThemeData(
    cursorColor: hostSelection,
    selectionColor: hostSelection,
    selectionHandleColor: hostSelection,
  ),
  inputDecorationTheme: const InputDecorationTheme(
    filled: true,
    fillColor: hostFill,
    hoverColor: hostOverlay,
    focusColor: hostOverlay,
    border: OutlineInputBorder(borderSide: BorderSide(color: hostBorder)),
    enabledBorder: OutlineInputBorder(
      borderSide: BorderSide(color: hostBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderSide: BorderSide(color: hostFocused),
    ),
    disabledBorder: OutlineInputBorder(
      borderSide: BorderSide(color: hostBorder),
    ),
    errorBorder: OutlineInputBorder(borderSide: BorderSide(color: hostBorder)),
    focusedErrorBorder: OutlineInputBorder(
      borderSide: BorderSide(color: hostFocused),
    ),
  ),
  scrollbarTheme: const ScrollbarThemeData(
    thumbColor: WidgetStatePropertyAll(hostOverlay),
    trackColor: WidgetStatePropertyAll(hostFill),
  ),
  tooltipTheme: const TooltipThemeData(
    decoration: BoxDecoration(color: hostFill),
    textStyle: TextStyle(color: hostText),
  ),
  iconTheme: const IconThemeData(color: hostText, size: 40),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(color: hostText, fontSize: 30),
    bodyLarge: TextStyle(color: hostText, fontSize: 30),
    titleMedium: TextStyle(color: hostText, fontSize: 30),
    labelLarge: TextStyle(color: hostText, fontSize: 30),
  ),
);

/// Wraps [child] in [hostileHostTheme], inside whatever Carbon harness the
/// test already uses.
Widget underHostileHost(Widget child) =>
    Theme(data: hostileHostTheme, child: child);

/// A `paints..something` predicate: true for a paint call that used a host
/// colour.
bool paintsHostColor(Symbol _, List<dynamic> args) => args.any(
  (a) =>
      (a is Paint && hostColors.contains(a.color)) ||
      (a is Color && hostColors.contains(a)),
);
