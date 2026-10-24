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

    test('custom schemes are refused', () {
      // A custom scheme could deep-link into another installed app.
      expect(resolve('antgrid://session/1'), MarkdownLinkTarget.unsupported);
    });

    test('a file URL is a local path for the bridge to judge', () {
      expect(
        resolve('file:///home/me/notes.md'),
        const MarkdownLinkTarget(
          MarkdownLinkKind.localPath,
          '/home/me/notes.md',
        ),
      );
      expect(
        resolve('file:///C:/Users/me/my%20notes.md').value,
        'C:/Users/me/my notes.md',
      );
      expect(
        resolve('file://localhost/home/me/a.md').kind,
        MarkdownLinkKind.localPath,
      );
    });

    test('a file URL naming another host is refused', () {
      // That is a network share; opening it would send credentials.
      expect(
        resolve('file://evil.example/share/a.md'),
        MarkdownLinkTarget.unsupported,
      );
    });

    test('a drive letter is a local path, not a scheme', () {
      expect(
        resolve(r'C:/notes.md'),
        const MarkdownLinkTarget(MarkdownLinkKind.localPath, 'C:/notes.md'),
      );
      expect(
        resolve(r'C:\Users\me\notes.md#top'),
        const MarkdownLinkTarget(
          MarkdownLinkKind.localPath,
          r'C:\Users\me\notes.md',
        ),
      );
      expect(resolve(r'C:\Users\me\'), MarkdownLinkTarget.unsupported);
    });

    test('a scheme matches however it is cased', () {
      expect(resolve('HTTPS://antgrid.ai').kind, MarkdownLinkKind.external);
      expect(
        resolve('FILE:///etc/notes.md').kind,
        MarkdownLinkKind.localPath,
      );
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
        resolve('../app/AGENTS.md', from: 'docs/architecture.md').value,
        'app/AGENTS.md',
      );
    });

    test('a leading slash is a local path that may mean the project root', () {
      expect(
        resolve('/AGENTS.md', from: 'docs/a.md'),
        const MarkdownLinkTarget(
          MarkdownLinkKind.localPath,
          '/AGENTS.md',
          repoFallback: 'AGENTS.md',
        ),
      );
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
