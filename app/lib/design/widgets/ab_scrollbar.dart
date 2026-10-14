import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';

/// The one scrollbar every file surface draws — code viewer, diff, markdown —
/// so a file reads the same wherever it is opened.
///
/// Always visible rather than fading with use: a code line or table that runs
/// past the viewport gives no other cue that there is more to the side, so the
/// thumb has to say so at a glance, not only once the pointer finds it. It
/// paints nothing when the content fits, so a narrow file shows no bar.
///
/// Geometry matches re_editor's own bar (`_RawScrollbar` in its
/// `_code_scroll.dart`), which this replaces in the file viewer.
class AbScrollbar extends RawScrollbar {
  const AbScrollbar({
    super.key,
    required super.child,
    required ScrollController super.controller,
    super.scrollbarOrientation,
    super.notificationPredicate,
  }) : super(
         thumbVisibility: true,
         thickness: 8,
         radius: const Radius.circular(10),
         crossAxisMargin: 2,
       );
}

/// A horizontal [SingleChildScrollView] under an [AbScrollbar], owning the
/// controller an always-visible thumb needs (a horizontal view has no
/// PrimaryScrollController to borrow).
class AbHorizontalScrollView extends StatefulWidget {
  const AbHorizontalScrollView({super.key, required this.child});

  final Widget child;

  @override
  State<AbHorizontalScrollView> createState() => _AbHorizontalScrollViewState();
}

class _AbHorizontalScrollViewState extends State<AbHorizontalScrollView> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AbScrollbar(
      controller: _controller,
      scrollbarOrientation: ScrollbarOrientation.bottom,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        // Room for the thumb, so it never sits on the last row's text.
        padding: const EdgeInsets.only(bottom: AbTokens.space12),
        child: widget.child,
      ),
    );
  }
}
