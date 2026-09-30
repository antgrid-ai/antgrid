import 'package:antgrid/design/widgets/ab_toast.dart';
import 'package:flutter/widgets.dart';

/// A `MaterialApp.builder` mounting the [AbToastHost] that `main.dart` mounts
/// around the Navigator. Without one in the tree every toast is a silent
/// no-op, so a test that asserts on a toast needs this.
Widget abToastHostBuilder(BuildContext context, Widget? child) =>
    AbToastHost(child: child!);
