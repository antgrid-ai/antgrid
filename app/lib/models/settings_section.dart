/// The addressable blocks of the app settings screen.
///
/// A model rather than a widget-layer type so `NavLocation` and the deep-link
/// codec can name a block without importing UI. The header text lives in the
/// `SettingsSectionUI` extension beside the sections themselves
/// (`screens/app_settings_screen.dart`), which is also what keys them.
///
/// These names are wire values — `section=` in an `antgrid://nav/settings`
/// link — so renaming one silently breaks links already written down.
enum SettingsSection {
  billing,
  connection,
  appearance,
  uiSize,
  accessibility,
  design,
  privacy,
  help,
  account,
}
