import 'package:fleather/fleather.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/widgets/transcript/composer/composer_controller.dart';

ComposerController fromDelta(List<Map<String, dynamic>> ops) =>
    ComposerController(document: ParchmentDocument.fromJson(ops));

void main() {
  group('toMarkdown', () {
    test('plain paragraph is identity', () {
      final c = fromDelta([
        {'insert': 'fix the login bug\n'},
      ]);
      expect(c.toMarkdown(), 'fix the login bug');
    });

    test('slash command line is identity', () {
      final c = fromDelta([
        {'insert': '/model opus\n'},
      ]);
      expect(c.toMarkdown(), '/model opus');
    });

    test('heading 1', () {
      final c = fromDelta([
        {'insert': 'Context'},
        {
          'insert': '\n',
          'attributes': {'heading': 1},
        },
      ]);
      expect(c.toMarkdown(), '# Context');
    });

    test('bullet list uses dash token', () {
      final c = fromDelta([
        {'insert': 'first'},
        {
          'insert': '\n',
          'attributes': {'block': 'ul'},
        },
        {'insert': 'second'},
        {
          'insert': '\n',
          'attributes': {'block': 'ul'},
        },
      ]);
      expect(c.toMarkdown(), '- first\n- second');
    });

    test('numbered list', () {
      final c = fromDelta([
        {'insert': 'step'},
        {
          'insert': '\n',
          'attributes': {'block': 'ol'},
        },
      ]);
      expect(c.toMarkdown(), '1. step');
    });

    test('code block fences', () {
      final c = fromDelta([
        {'insert': 'final x = 1;'},
        {
          'insert': '\n',
          'attributes': {'block': 'code'},
        },
      ]);
      expect(c.toMarkdown(), '```\nfinal x = 1;\n```');
    });

    test('quote', () {
      final c = fromDelta([
        {'insert': 'cited'},
        {
          'insert': '\n',
          'attributes': {'block': 'quote'},
        },
      ]);
      expect(c.toMarkdown(), '> cited');
    });

    test('mixed document keeps block order', () {
      final c = fromDelta([
        {'insert': 'Title'},
        {
          'insert': '\n',
          'attributes': {'heading': 2},
        },
        {'insert': 'body\n'},
        {'insert': 'item'},
        {
          'insert': '\n',
          'attributes': {'block': 'ul'},
        },
      ]);
      final md = c.toMarkdown();
      expect(md, contains('## Title'));
      expect(md, contains('body'));
      expect(md, contains('- item'));
      expect(
        md.indexOf('## Title') < md.indexOf('body') &&
            md.indexOf('body') < md.indexOf('- item'),
        isTrue,
      );
    });
  });

  group('state', () {
    test(
      'isEmpty on fresh controller, false after insert, true after clear',
      () {
        final c = ComposerController();
        expect(c.isEmpty, isTrue);
        c.fleather.replaceText(0, 0, 'hi');
        expect(c.isEmpty, isFalse);
        c.clear();
        expect(c.isEmpty, isTrue);
      },
    );

    test('notifies listeners on document change', () {
      final c = ComposerController();
      var ticks = 0;
      c.addListener(() => ticks++);
      c.fleather.replaceText(0, 0, 'x');
      expect(ticks, greaterThan(0));
    });
  });

  group('firstLine', () {
    test('caret within first line', () {
      final c = fromDelta([
        {'insert': '/mod\nsecond\n'},
      ]);
      c.fleather.updateSelection(
        const TextSelection.collapsed(offset: 4),
        source: ChangeSource.local,
      );
      expect(c.firstLine, (text: '/mod', caret: 4));
    });

    test('null when caret is past the first line', () {
      final c = fromDelta([
        {'insert': 'one\ntwo\n'},
      ]);
      c.fleather.updateSelection(
        const TextSelection.collapsed(offset: 6),
        source: ChangeSource.local,
      );
      expect(c.firstLine, isNull);
    });
  });

  group('caretLineIsPlain', () {
    test('true on plain text, false on heading line', () {
      final plain = fromDelta([
        {'insert': '/model\n'},
      ]);
      plain.fleather.updateSelection(
        const TextSelection.collapsed(offset: 3),
        source: ChangeSource.local,
      );
      expect(plain.caretLineIsPlain, isTrue);

      final heading = fromDelta([
        {'insert': 'Title'},
        {
          'insert': '\n',
          'attributes': {'heading': 1},
        },
      ]);
      heading.fleather.updateSelection(
        const TextSelection.collapsed(offset: 3),
        source: ChangeSource.local,
      );
      expect(heading.caretLineIsPlain, isFalse);
    });
  });

  group('mentionToken', () {
    // Places a collapsed caret at [offset] — mentionToken is caret-relative.
    void caret(ComposerController c, int offset) => c.fleather.updateSelection(
      TextSelection.collapsed(offset: offset),
      source: ChangeSource.local,
    );

    test('bare @ at doc start yields empty query', () {
      final c = fromDelta([
        {'insert': '@\n'},
      ]);
      caret(c, 1);
      expect(c.mentionToken, (start: 0, query: ''));
    });

    test('@ after whitespace mid-doc yields typed query', () {
      final c = fromDelta([
        {'insert': 'fix @li\n'},
      ]);
      caret(c, 7);
      expect(c.mentionToken, (start: 4, query: 'li'));
    });

    test('caret mid-query only sees text left of the caret', () {
      final c = fromDelta([
        {'insert': 'fix @lib\n'},
      ]);
      caret(c, 6);
      expect(c.mentionToken, (start: 4, query: 'l'));
    });

    test('email-like a@b does not trigger', () {
      final c = fromDelta([
        {'insert': 'a@b\n'},
      ]);
      caret(c, 3);
      expect(c.mentionToken, isNull);
    });

    test('whitespace between @ and caret ends the token', () {
      final c = fromDelta([
        {'insert': '@foo bar\n'},
      ]);
      caret(c, 8);
      expect(c.mentionToken, isNull);
    });

    test('nearest @ wins when the message has several', () {
      final c = fromDelta([
        {'insert': 'see @a.txt @li\n'},
      ]);
      caret(c, 14);
      expect(c.mentionToken, (start: 11, query: 'li'));
    });

    test('@@ does not trigger (prev char not whitespace)', () {
      final c = fromDelta([
        {'insert': '@@x\n'},
      ]);
      caret(c, 3);
      expect(c.mentionToken, isNull);
    });

    test('null for a range selection', () {
      final c = fromDelta([
        {'insert': '@li\n'},
      ]);
      c.fleather.updateSelection(
        const TextSelection(baseOffset: 1, extentOffset: 3),
        source: ChangeSource.local,
      );
      expect(c.mentionToken, isNull);
    });

    test('null on a code-block line', () {
      final c = fromDelta([
        {'insert': '@li'},
        {
          'insert': '\n',
          'attributes': {'block': 'code'},
        },
      ]);
      caret(c, 3);
      expect(c.mentionToken, isNull);
    });

    test('newline stops the backward scan', () {
      final c = fromDelta([
        {'insert': '@lib\nx\n'},
      ]);
      caret(c, 6);
      expect(c.mentionToken, isNull);
    });
  });

  group('acceptMention', () {
    void caret(ComposerController c, int offset) => c.fleather.updateSelection(
      TextSelection.collapsed(offset: offset),
      source: ChangeSource.local,
    );

    test('replaces the token and places caret after the trailing space', () {
      final c = fromDelta([
        {'insert': 'fix @li\n'},
      ]);
      caret(c, 7);
      c.acceptMention('lib/main.dart');
      expect(c.fleather.document.toPlainText(), 'fix @lib/main.dart \n');
      expect(c.fleather.selection.baseOffset, 'fix @lib/main.dart '.length);
    });

    test('bare @ accepts into a full mention', () {
      final c = fromDelta([
        {'insert': '@\n'},
      ]);
      caret(c, 1);
      c.acceptMention('lib/main.dart');
      expect(c.fleather.document.toPlainText(), '@lib/main.dart \n');
      expect(c.fleather.selection.baseOffset, '@lib/main.dart '.length);
    });

    test('caret mid-query replaces the WHOLE token (no leftover suffix)', () {
      final c = fromDelta([
        {'insert': 'see @lib here\n'},
      ]);
      caret(c, 6); // see @l|ib here
      c.acceptMention('lib/main.dart');
      expect(c.fleather.document.toPlainText(), 'see @lib/main.dart here\n');
      expect(c.fleather.selection.baseOffset, 'see @lib/main.dart '.length);
    });

    test('absorbs one existing trailing space (no double space)', () {
      final c = fromDelta([
        {'insert': 'see @li here\n'},
      ]);
      caret(c, 7); // see @li| here
      c.acceptMention('lib/main.dart');
      expect(c.fleather.document.toPlainText(), 'see @lib/main.dart here\n');
      expect(c.fleather.selection.baseOffset, 'see @lib/main.dart '.length);
    });

    test('no-op when no mention token is active', () {
      final c = fromDelta([
        {'insert': 'a@b\n'},
      ]);
      caret(c, 3);
      c.acceptMention('lib/main.dart');
      expect(c.fleather.document.toPlainText(), 'a@b\n');
    });
  });

  group('acceptCommand', () {
    test('replaces bare token and appends trailing space', () {
      final c = fromDelta([
        {'insert': '/mod\n'},
      ]);
      c.acceptCommand('model');
      expect(c.fleather.document.toPlainText(), '/model \n');
      expect(c.fleather.selection.baseOffset, '/model '.length);
    });

    test('preserves args after the token', () {
      final c = fromDelta([
        {'insert': '/mod opus fast\n'},
      ]);
      c.acceptCommand('model');
      expect(c.fleather.document.toPlainText(), '/model opus fast\n');
      expect(c.fleather.selection.baseOffset, '/model '.length);
    });
  });

  group('appendText', () {
    test('seeds an empty composer and leaves the caret on a fresh line', () {
      final c = fromDelta([
        {'insert': '\n'},
      ]);
      c.appendText('[from preview: http://localhost:3000/]');

      expect(c.toMarkdown(), '[from preview: http://localhost:3000/]');
      // Caret past the seeded line, so what the user types next is their own
      // sentence rather than an edit of the handoff.
      expect(
        c.fleather.selection.baseOffset,
        '[from preview: http://localhost:3000/]\n'.length,
      );
    });

    test('appends under an existing draft instead of replacing it', () {
      final c = fromDelta([
        {'insert': 'already typing\n'},
      ]);
      c.appendText('[from preview: http://localhost:3000/]');

      expect(
        c.toMarkdown(),
        'already typing\n\n[from preview: http://localhost:3000/]',
      );
    });

    test('empty or blank text is a no-op', () {
      final c = fromDelta([
        {'insert': 'draft\n'},
      ]);
      c.appendText('   ');
      expect(c.toMarkdown(), 'draft');
    });
  });
}
