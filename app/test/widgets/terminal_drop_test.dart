// Dropping a file onto the terminal. The one thing that must never regress is
// that the BYTES travel: forwarding the local path the OS reports would look
// right on a local session and silently name a file the remote agent cannot
// open. The rest of what is pinned here is what a drop can lose quietly — the
// extras of a multi-file drop, and a read that fails while another file is
// still uploading.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid/services/upload_service.dart';
import 'package:antgrid/widgets/terminal_attachment_uploader.dart';
import 'package:antgrid/widgets/terminal_drop_target.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDropped implements DroppedFile {
  _FakeDropped({
    this.name,
    this.imageHint,
    Uint8List? bytes,
    this.readsNothing = false,
    this.readError,
    this.gate,
  }) : bytes = bytes ?? Uint8List.fromList([1, 2, 3]);

  final String? name;
  @override
  final (String extension, String mimeType)? imageHint;
  final Uint8List bytes;

  /// The item advertised a format it turned out not to hold.
  final bool readsNothing;
  final Object? readError;
  final Completer<void>? gate;

  /// Counts synchronous entries into [read], which is what proves the reads
  /// were started while the drag data was still live.
  int started = 0;

  /// Every limit [read] was handed, so the caller's default is checkable.
  final List<int> seenLimits = [];

  @override
  Future<String?> suggestedName() async => name;

  @override
  Future<Uint8List?> read({required int limit}) async {
    started++;
    seenLimits.add(limit);
    if (gate != null) await gate!.future;
    if (readError != null) throw readError!;
    // Honoured, not ignored: the real item refuses by this limit, so a fake
    // that shrugged it off would let `performTerminalDrop` stop passing it.
    if (bytes.length > limit) throw const UploadException('TOO_LARGE', '');
    return readsNothing ? null : bytes;
  }
}

/// An item whose reader fails SYNCHRONOUSLY, which `_FakeDropped` cannot do —
/// its `read` is `async`, so every throw it raises is already a rejection.
/// A real `getFile` can raise on the spot, before the started-list is even
/// finished being built.
class _SyncThrowingDropped implements DroppedFile {
  @override
  (String, String)? get imageHint => null;

  @override
  Future<String?> suggestedName() async => 'boom.png';

  @override
  Future<Uint8List?> read({required int limit}) =>
      throw StateError('adapter gone');
}

/// One drop, run through the real shared uploader over a fake upload runner —
/// so the quoted-path insert, the busy state and the failure copy are the
/// production ones.
class _Harness {
  _Harness({UploadRunner? runner}) {
    this.runner =
        runner ??
        ({required fileName, required bytes, mimeType, onProgress}) async {
          staged.add((fileName, bytes.length, mimeType));
          return '/staged/$fileName';
        };
  }

  late final UploadRunner runner;
  final List<(String name, int size, String? mime)> staged = [];
  final List<String> inserted = [];
  final List<String> errors = [];

  late final TerminalAttachmentUploader uploader = TerminalAttachmentUploader(
    resolveUpload: () => runner,
    insert: inserted.add,
    onError: errors.add,
  );

  Future<void> drop(List<DroppedFile> items, {int? limit}) =>
      performTerminalDrop(
        items: items,
        attach: uploader.attach,
        onError: errors.add,
        limit: limit ?? UploadService.kMaxUploadBytes,
      );
}

void main() {
  group('performTerminalDrop', () {
    test(
      'uploads the dropped bytes and types the returned host path',
      () async {
        final h = _Harness();
        addTearDown(h.uploader.dispose);

        await h.drop([
          _FakeDropped(
            name: 'shot.png',
            imageHint: ('png', 'image/png'),
            bytes: Uint8List.fromList([9, 9, 9, 9]),
          ),
        ]);

        // The bytes went up; nothing about the user's own path did.
        expect(h.staged, [('shot.png', 4, 'image/png')]);
        expect(h.inserted, ['"/staged/shot.png" ']);
        expect(h.errors, isEmpty);
      },
    );

    test('an oversize item is refused and never reaches the uploader', () async {
      final h = _Harness();
      addTearDown(h.uploader.dispose);

      // The limit reaches the item, which is the whole point of reading behind
      // a cap: without it the bytes are already in memory by the time anything
      // could refuse them.
      await h.drop([
        _FakeDropped(name: 'huge.bin', bytes: Uint8List(9)),
      ], limit: 8);

      expect(h.staged, isEmpty);
      expect(h.inserted, isEmpty);
      expect(h.errors.single, contains('20 MB'));
    });

    test('the cap defaults to the upload service maximum', () async {
      final h = _Harness();
      addTearDown(h.uploader.dispose);
      final item = _FakeDropped(name: 'a.png');

      await performTerminalDrop(
        items: [item],
        attach: h.uploader.attach,
        onError: h.errors.add,
      );

      expect(item.seenLimits.single, UploadService.kMaxUploadBytes);
      expect(h.errors, isEmpty);
    });

    test('a failed upload reports and inserts nothing', () async {
      final h = _Harness(
        runner:
            ({required fileName, required bytes, mimeType, onProgress}) async =>
                throw const UploadException('OFFLINE', ''),
      );
      addTearDown(h.uploader.dispose);

      await h.drop([_FakeDropped(name: 'notes.md')]);

      expect(h.inserted, isEmpty);
      expect(h.errors.single, contains('notes.md'));
    });

    test('every file of a multi-file drop is uploaded, in order', () async {
      final h = _Harness();
      addTearDown(h.uploader.dispose);

      await h.drop([
        _FakeDropped(name: 'a.png', bytes: Uint8List(1)),
        _FakeDropped(name: 'b.png', bytes: Uint8List(2)),
        _FakeDropped(name: 'c.png', bytes: Uint8List(3)),
      ]);

      expect(h.staged.map((s) => s.$1), ['a.png', 'b.png', 'c.png']);
      expect(h.inserted, [
        '"/staged/a.png" ',
        '"/staged/b.png" ',
        '"/staged/c.png" ',
      ]);
      // Sequential, so the single-flight uploader never refuses its own queue.
      expect(h.errors, isEmpty);
    });

    test('every read starts before the first upload is awaited', () async {
      final h = _Harness();
      addTearDown(h.uploader.dispose);
      final first = Completer<void>();
      final items = [
        _FakeDropped(name: 'a.png', gate: first),
        _FakeDropped(name: 'b.png'),
      ];

      final run = h.drop(items);
      // The platform's drag data is only live for the duration of
      // `onPerformDrop`; a read deferred until a.png finished uploading would
      // be reading from a released session.
      expect(items.map((i) => i.started), [1, 1]);

      first.complete();
      await run;
      expect(h.staged.map((s) => s.$1), ['a.png', 'b.png']);
    });

    test(
      'a read that fails while another file uploads is still reported',
      () async {
        final h = _Harness();
        addTearDown(h.uploader.dispose);
        final gate = Completer<void>();

        final run = h.drop([
          _FakeDropped(name: 'a.png', gate: gate),
          _FakeDropped(
            name: 'b.png',
            readError: const UploadException('TOO_LARGE', ''),
          ),
        ]);
        // b.png rejects here, long before anything awaits it — with no handler
        // attached at that moment it would be an unhandled async error.
        await pumpEventQueue();
        gate.complete();
        await run;

        expect(h.staged.map((s) => s.$1), ['a.png']);
        expect(h.errors.single, contains('b.png'));
      },
    );

    test(
      'a reader that throws synchronously loses one file, not the drop',
      () async {
        final h = _Harness();
        addTearDown(h.uploader.dispose);

        await h.drop([_SyncThrowingDropped(), _FakeDropped(name: 'b.png')]);

        // The throw lands while the started-list is still being built, before any
        // per-file handler exists — unfolded it would abandon every later file
        // with nothing on screen to say so.
        expect(h.errors.single, contains('boom.png'));
        expect(h.staged.map((s) => s.$1), ['b.png']);
      },
    );

    test(
      'an item that turns out to carry nothing is reported, not skipped',
      () async {
        final h = _Harness();
        addTearDown(h.uploader.dispose);

        await h.drop([_FakeDropped(name: 'ghost.png', readsNothing: true)]);

        expect(h.staged, isEmpty);
        expect(h.errors.single, contains('ghost.png'));
      },
    );
  });

  // The cap that keeps a 2 GB drop from being buffered into app memory just to
  // be refused. Both halves are load-bearing and neither covers the other.
  group('readCapped', () {
    Stream<Uint8List> chunks(List<int> sizes) =>
        Stream.fromIterable(sizes.map(Uint8List.new));

    test('returns the bytes when the file fits', () async {
      final bytes = await readCapped(
        declaredSize: 6,
        stream: () => chunks([3, 3]),
        limit: 8,
      );
      expect(bytes, hasLength(6));
    });

    test('refuses on the declared size without reading a byte', () async {
      var opened = false;
      await expectLater(
        readCapped(
          declaredSize: 4096,
          stream: () {
            opened = true;
            return chunks([4096]);
          },
          limit: 8,
        ),
        throwsA(
          isA<UploadException>().having((e) => e.code, 'code', 'TOO_LARGE'),
        ),
      );
      expect(opened, isFalse);
    });

    test('refuses mid-stream when the platform declared no size', () async {
      // The common case for a virtual/promised file: nothing to refuse it by
      // up front, so the running count is the only thing standing between a
      // huge drop and app memory.
      var delivered = 0;
      await expectLater(
        readCapped(
          declaredSize: null,
          stream: () => Stream.fromIterable(List.filled(100, 4)).map((size) {
            delivered += size;
            return Uint8List(size);
          }),
          limit: 8,
        ),
        throwsA(
          isA<UploadException>().having((e) => e.code, 'code', 'TOO_LARGE'),
        ),
      );
      // Abandoned as soon as the count passed the limit, not after the whole
      // 400 bytes had been buffered.
      expect(delivered, 12);
    });

    test('a declared size at the limit exactly is allowed through', () async {
      expect(
        await readCapped(declaredSize: 8, stream: () => chunks([8]), limit: 8),
        hasLength(8),
      );
    });
  });

  group('droppedFileName', () {
    final at = DateTime(2026, 8, 19, 14, 12, 33);

    test('keeps the reported name, extension included', () {
      expect(droppedFileName('report.pdf', null, now: at), 'report.pdf');
      // The advertised image format must not overwrite a real extension.
      expect(droppedFileName('server.log', 'png', now: at), 'server.log');
    });

    test('reduces a name to the alphabet the bridge sanitizer keeps', () {
      expect(
        droppedFileName(r'C:\shots\my shot#1.png', null, now: at),
        'my shot_1.png',
      );
      expect(droppedFileName('.hidden.txt', null, now: at), 'hidden.txt');
    });

    test('lends the advertised image extension to an extensionless name', () {
      expect(droppedFileName('screenshot', 'png', now: at), 'screenshot.png');
      expect(droppedFileName('screenshot', null, now: at), 'screenshot');
    });

    test('synthesizes a name for raw dragged bytes', () {
      // Raw image data reports no name on any platform.
      expect(
        droppedFileName(null, 'png', now: at),
        'dropped-20260819-141233.png',
      );
      expect(
        droppedFileName('///', null, now: at),
        'dropped-20260819-141233.bin',
      );
    });
  });
}
