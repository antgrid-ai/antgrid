import 'package:markdown_widget/markdown_widget.dart';

/// markdown_widget draws a [Divider] rule under H1/H2/H3 by default
/// (`HeadingDivider.h1`/`.h2`/`.h3`), and the divider is a getter override on
/// the config, not a constructor argument — so the only way to suppress it is
/// to subclass and null the getter. We render headings by weight and size
/// alone, no rule line, so both the transcript and the file preview use these.
/// H4-H6 already inherit `divider => null`, so they need no wrapper.
class H1ConfigNoRule extends H1Config {
  const H1ConfigNoRule({super.style});
  @override
  HeadingDivider? get divider => null;
}

class H2ConfigNoRule extends H2Config {
  const H2ConfigNoRule({super.style});
  @override
  HeadingDivider? get divider => null;
}

class H3ConfigNoRule extends H3Config {
  const H3ConfigNoRule({super.style});
  @override
  HeadingDivider? get divider => null;
}
