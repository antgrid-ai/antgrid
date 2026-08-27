import 'package:flutter_driver/driver_extension.dart';
import 'package:antgrid/main.dart' as app;
import 'package:antgrid/navigation/nav_console.dart';

void main(List<String> args) {
  enableFlutterDriverExtension();
  // Set before the app builds: this entry point is the only thing that turns the
  // nav console on, because a driven app differs from a normal one by `target:`
  // alone — there is no build flag for a --dart-define to key off.
  kNavConsoleEnabled = true;
  app.main(args);
}
