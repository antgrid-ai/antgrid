import 'package:fleather/fleather.dart';
import 'package:flutter/widgets.dart';

import '../widgets/transcript/composer/composer_controller.dart';

/// A disposable preview keeps partial hypotheses out of the draft's history.
class VoiceComposerBinding {
  VoiceComposerBinding(this.original, this.onManualEdit)
    : selection = original.fleather.selection,
      before = original.fleather.document.toDelta() {
    preview = ComposerController(document: ParchmentDocument.fromDelta(before));
    preview.fleather.updateSelection(selection);
    _last = preview.fleather.document.toDelta();
    preview.addListener(_changed);
  }
  final ComposerController original;
  final VoidCallback onManualEdit;
  final TextSelection selection;
  final Delta before;
  late final ComposerController preview;
  bool _internal = false;
  bool _finished = false;
  int _length = 0;
  int _markedStart = 0;
  Delta? _last;
  int get _start => selection.isValid
      ? selection.start
      : original.fleather.document.length - 1;
  int get _replaced => selection.isValid ? selection.end - selection.start : 0;

  void update(String text) {
    if (_finished) return;
    _internal = true;
    final body = before
        .toList()
        .where((op) => op.isInsert)
        .map((op) => op.data is String ? op.data : '\uFFFC')
        .join();
    final prefix =
        _start > 0 &&
            !RegExp(r'\s').hasMatch(body[_start - 1]) &&
            text.isNotEmpty
        ? ' '
        : '';
    final end = _start + _replaced;
    final suffix =
        end < body.length &&
            !RegExp(r'[\s.,;:!?)]').hasMatch(body[end]) &&
            text.isNotEmpty
        ? ' '
        : '';
    final insert = '$prefix$text$suffix';
    final desired = before.compose(
      Delta()
        ..retain(_start)
        ..delete(_replaced)
        ..insert(insert),
    );
    preview.fleather.compose(
      preview.fleather.document.toDelta().diff(desired),
      source: ChangeSource.history,
      selection: TextSelection.collapsed(offset: _start + insert.length),
    );
    _length = insert.length;
    _markedStart = _start;
    if (_length > 0) {
      preview.fleather.formatText(
        _start,
        _length,
        ParchmentAttribute.underline,
      );
    }
    _last = preview.fleather.document.toDelta();
    _internal = false;
  }

  void _changed() {
    if (_internal || _finished) return;
    final current = preview.fleather.document.toDelta();
    if (_last != current) {
      final change = _last!.diff(current);
      final end = change.transformPosition(_markedStart + _length, force: true);
      _markedStart = change.transformPosition(_markedStart);
      _length = (end - _markedStart).clamp(
        0,
        preview.fleather.document.length - 1,
      );
      onManualEdit();
    }
  }

  void finish({required bool keep}) {
    if (_finished) return;
    _finished = true;
    if (!keep) return;
    if (_length > 0 && _markedStart < preview.fleather.document.length - 1) {
      preview.fleather.formatText(
        _markedStart,
        _length.clamp(0, preview.fleather.document.length - 1 - _markedStart),
        ParchmentAttribute.underline.unset,
      );
    }
    final edits = before.diff(preview.fleather.document.toDelta());
    final incoming = before.diff(original.fleather.document.toDelta());
    // Rebase the entire edited preview, not just the recognition hypothesis,
    // so an independent handoff cannot erase manual corrections.
    final rebased = incoming.transform(edits, true);
    final incomingOnPreview = edits.transform(incoming, false);
    final caret = preview.fleather.selection;
    original.fleather.compose(
      rebased,
      selection: caret.isValid
          ? TextSelection(
              baseOffset: incomingOnPreview.transformPosition(caret.baseOffset),
              extentOffset: incomingOnPreview.transformPosition(
                caret.extentOffset,
              ),
              affinity: caret.affinity,
              isDirectional: caret.isDirectional,
            )
          : caret,
    );
  }

  void dispose() {
    preview.removeListener(_changed);
    preview.dispose();
  }
}
