import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/util/markdown_link_target.dart';

void main() {
  group('resolveMarkdownLink', () {
    MarkdownLinkTarget resolve(String href, {String from = 'README.md'}) =>
        resolveMarkdownLink(href, fromPath: from);

    test('web addresses open externally', () {
      expect(
        resolve('https://antgrid.ai/docs'),
        const MarkdownLinkTarget(
          MarkdownLinkKind.external,
          'https://antgrid.ai/docs',
        ),
      );
      expect(resolve('mailto:hi@antgrid.ai').kind, MarkdownLinkKind.external);
    });

    test('non-web schemes are refused', () {
      // A doc is repository content; `file:` would hand out local paths and a
      // custom scheme could deep-link into another installed app.
      expect(resolve('file:///etc/passwd'), MarkdownLinkTarget.unsupported);
      expect(resolve('antgrid://session/1'), MarkdownLinkTarget.unsupported);
    });

    test('a drive letter is a path, not a scheme', () {
      expect(resolve(r'C:/notes.md').kind, isNot(MarkdownLinkKind.external));
      // And not a repo file either — joining it onto the open file's directory
      // would name `docs/C:/notes.md`.
      expect(resolve(r'C:/notes.md'), MarkdownLinkTarget.unsupported);
    });

    test('a scheme matches however it is cased', () {
      expect(resolve('HTTPS://antgrid.ai').kind, MarkdownLinkKind.external);
      expect(resolve('FILE:///etc/passwd'), MarkdownLinkTarget.unsupported);
    });

    test('a protocol-relative URL is not a path in the checkout', () {
      // `//evil.example/x` has an authority and no scheme, so resolving it
      // against the open file would open a file named after a hostname.
      expect(resolve('//evil.example/x.md'), MarkdownLinkTarget.unsupported);
    });

    test('a web address with no host opens nothing', () {
      expect(resolve('https:///docs'), MarkdownLinkTarget.unsupported);
    });

    test('sibling and nested paths resolve against the open file', () {
      expect(
        resolve('docs/architecture.md'),
        const MarkdownLinkTarget(
          MarkdownLinkKind.repoFile,
          'docs/architecture.md',
        ),
      );
      expect(
        resolve('./commands.md', from: 'docs/architecture.md').value,
        'docs/commands.md',
      );
      expect(
        resolve('../app/CLAUDE.md', from: 'docs/architecture.md').value,
        'app/CLAUDE.md',
      );
    });

    test('a leading slash means the project root', () {
      expect(resolve('/CLAUDE.md', from: 'docs/a.md').value, 'CLAUDE.md');
    });

    test('a link climbing past the project root has no destination', () {
      expect(
        resolve('../../secrets.md', from: 'docs/a.md'),
        MarkdownLinkTarget.unsupported,
      );
    });

    test('fragments and queries are trimmed off a file path', () {
      expect(
        resolve('docs/architecture.md#message-flow').value,
        'docs/architecture.md',
      );
    });

    test('percent escapes are decoded', () {
      expect(resolve('docs/my%20notes.md').value, 'docs/my notes.md');
    });

    test('an escape that is not UTF-8 is left literal, never thrown', () {
      // `%E9` is latin-1 `é`: syntactically valid, so `decodeComponent` gets
      // past its own argument check and throws a FormatException on the bytes.
      // This runs inside a tap handler, where a throw is a crash.
      expect(resolve('docs/caf%E9.md').kind, MarkdownLinkKind.repoFile);
      expect(resolve('docs/50%.md').kind, MarkdownLinkKind.repoFile);
    });

    test('a directory is not a destination the viewer can open', () {
      expect(resolve('docs/'), MarkdownLinkTarget.unsupported);
      expect(resolve(''), MarkdownLinkTarget.unsupported);
    });

    test('a bare fragment targets a heading in this document', () {
      expect(
        resolve('#design-rules'),
        const MarkdownLinkTarget(MarkdownLinkKind.anchor, 'design-rules'),
      );
      expect(resolve('#'), MarkdownLinkTarget.unsupported);
    });
  });

  group('slugifyMarkdownHeading', () {
    test('folds a heading the way an in-document anchor is written', () {
      expect(
        slugifyMarkdownHeading('Design Rules (app UI)'),
        'design-rules-app-ui',
      );
      expect(slugifyMarkdownHeading('  Test, typecheck, lint '), 'test-typecheck-lint');
    });

    test('matches a heading set in inline code', () {
      expect(slugifyMarkdownHeading('copyWith'), 'copywith');
    });

    test('stripped punctuation still leaves its own hyphen', () {
      // One hyphen per whitespace CHARACTER, like `package:markdown`'s
      // `generateAnchorHash`, which is what wrote the id being matched:
      // dropping the `&` leaves two spaces, so the anchor is `dev--setup`.
      expect(slugifyMarkdownHeading('Dev & setup'), 'dev--setup');
      expect(
        slugifyMarkdownHeading('Test, typecheck, lint'),
        'test-typecheck-lint',
      );
    });
  });
}
