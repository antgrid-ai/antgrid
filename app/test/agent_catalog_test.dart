import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/agent_catalog_store.dart';

import 'helpers/prefs_test_mock.dart';

Map<String, dynamic> _wire(
  String tool, {
  String? label,
  bool chatCapable = false,
  bool judgeCapable = false,
  bool handlerTerminal = false,
  bool handlerChat = false,
}) => {
  'tool': tool,
  'label': label ?? tool,
  'chatCapable': chatCapable,
  'judgeCapable': judgeCapable,
  'handler': {'terminal': handlerTerminal, 'chat': handlerChat},
};

AgentDescriptor _d(
  String tool, {
  String? label,
  bool chatCapable = false,
  bool judgeCapable = false,
  bool handlerTerminal = false,
  bool handlerChat = false,
}) => AgentDescriptor(
  tool: tool,
  label: label ?? tool,
  chatCapable: chatCapable,
  judgeCapable: judgeCapable,
  handlerTerminal: handlerTerminal,
  handlerChat: handlerChat,
);

SessionEntry _session({String? tool, String? command}) => SessionEntry(
  id: 's1',
  name: 'a session',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  tool: tool,
  command: command,
);

/// Lets the notifier's unawaited disk hydration — and the write it may chain
/// behind it — land.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  group('AgentDescriptor.fromJson', () {
    test('parses a complete descriptor', () {
      final d = AgentDescriptor.fromJson(
        _wire(
          'codex',
          label: 'Codex',
          chatCapable: true,
          judgeCapable: true,
          handlerTerminal: true,
          handlerChat: true,
        ),
      );
      expect(d, isNotNull);
      expect(d!.label, 'Codex');
      expect(d.chatCapable, isTrue);
      expect(d.judgeCapable, isTrue);
      expect(d.handlerTerminal, isTrue);
      expect(d.handlerChat, isTrue);
    });

    test('drops a partial descriptor rather than defaulting its fields', () {
      // A missing field would otherwise become a confident `false`, which is the
      // exact failure the descriptor exists to remove.
      final partial = _wire('codex')..remove('judgeCapable');
      expect(AgentDescriptor.fromJson(partial), isNull);
      final noHandler = _wire('codex')..remove('handler');
      expect(AgentDescriptor.fromJson(noHandler), isNull);
      expect(
        AgentDescriptor.fromJson({
          ..._wire('codex'),
          'handler': {'chat': true},
        }),
        isNull,
      );
    });

    test('round-trips through toJson', () {
      final d = AgentDescriptor.fromJson(
        _wire('opencode', label: 'opencode', chatCapable: true),
      )!;
      expect(AgentDescriptor.fromJson(d.toJson()), d);
    });
  });

  group('parseAgentDescriptors', () {
    test('an absent array is empty, not a guess', () {
      expect(parseAgentDescriptors(null), isEmpty);
      expect(parseAgentDescriptors('nonsense'), isEmpty);
    });

    test('one malformed row degrades one agent, not all of them', () {
      final parsed = parseAgentDescriptors([
        _wire('codex'),
        {'tool': 'broken'},
        _wire('kilo'),
      ]);
      expect(parsed.map((d) => d.tool), ['codex', 'kilo']);
    });
  });

  group('agentCatalogProvider', () {
    test('merges adverts across machines, latest advert winning per key', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(agentCatalogProvider.notifier);

      notifier.merge([_d('codex', label: 'Codex')]);
      notifier.merge([
        _d('kilo', label: 'Kilo'),
        _d('codex', label: 'Codex 2'),
      ]);

      expect(container.read(agentCatalogProvider).keys, ['codex', 'kilo']);
      expect(container.read(agentCatalogProvider)['codex']!.label, 'Codex 2');
    });

    test('an empty advert is a no-op, never a clear', () {
      // An older bridge sends no descriptor at all; dropping the cache on it
      // would blank every label the moment such a machine connected.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(agentCatalogProvider.notifier);

      notifier.merge([_d('codex', label: 'Codex')]);
      notifier.merge(const []);

      expect(container.read(agentCatalogProvider)['codex']!.label, 'Codex');
    });

    test('persists across containers', () async {
      final first = ProviderContainer();
      first.read(agentCatalogProvider.notifier).merge([
        _d('kilo', label: 'Kilo'),
      ]);
      await _settle();
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      second.read(agentCatalogProvider);
      await _settle();
      expect(second.read(agentCatalogProvider)['kilo']?.label, 'Kilo');
    });

    test(
      'a live advert outranks the disk read that was still in flight',
      () async {
        await AgentCatalogStore().write({'codex': _d('codex', label: 'stale')});

        final container = ProviderContainer();
        addTearDown(container.dispose);
        // Build, then merge before the hydration future completes.
        container.read(agentCatalogProvider);
        container.read(agentCatalogProvider.notifier).merge([
          _d('codex', label: 'fresh'),
        ]);
        await _settle();

        expect(container.read(agentCatalogProvider)['codex']!.label, 'fresh');
      },
    );

    test(
      'an advert that beats the disk read still leaves the cache on disk',
      () async {
        // The store REPLACES the blob, so an advert persisting from pre-hydration
        // state would drop every previously cached agent — and the union the
        // hydrate then builds in memory would never reach disk, making the loss
        // permanent across restarts.
        await AgentCatalogStore().write({'kilo': _d('kilo', label: 'Kilo')});

        final first = ProviderContainer();
        first.read(agentCatalogProvider);
        first.read(agentCatalogProvider.notifier).merge([
          _d('codex', label: 'Codex'),
        ]);
        await _settle();
        first.dispose();

        expect((await AgentCatalogStore().read()).keys, contains('kilo'));

        final second = ProviderContainer();
        addTearDown(second.dispose);
        second.read(agentCatalogProvider);
        await _settle();
        expect(
          second.read(agentCatalogProvider).keys,
          unorderedEquals(['kilo', 'codex']),
        );
      },
    );
  });

  group('judgeCapableToolsProvider', () {
    test('lists only judge-capable keys, in a launch-stable order', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Advert order is whichever machine spoke first, so the picker must not
      // inherit it.
      container.read(agentCatalogProvider.notifier).merge([
        _d('codex', judgeCapable: true),
        _d('cursor-agent'),
        _d('claude-code', judgeCapable: true),
      ]);
      expect(container.read(judgeCapableToolsProvider), [
        'claude-code',
        'codex',
      ]);
    });

    test('is empty until some bridge has described an agent', () {
      // The app ships no list of its own, so an undescribed catalog leaves the
      // picker with nothing but its Default entry.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(judgeCapableToolsProvider), isEmpty);
    });

    test('a bridge that answered has answered fully', () {
      // Including when the answer is "none" — nothing supplements it.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(agentCatalogProvider.notifier).merge([_d('cursor-agent')]);
      expect(container.read(judgeCapableToolsProvider), isEmpty);
    });
  });

  group('handlerObservableFromCatalog', () {
    // opencode's shape: its in-runtime plugin posts /handler-event, so both
    // modes are watchable. cursor-agent posts none, so neither is.
    final catalog = {
      'opencode': _d('opencode', handlerTerminal: true, handlerChat: true),
      'cursor-agent': _d('cursor-agent'),
    };

    test('answers per mode, since an agent can be watchable in only one', () {
      expect(
        handlerObservableFromCatalog(catalog, 'opencode', chat: false),
        isTrue,
      );
      expect(
        handlerObservableFromCatalog(catalog, 'cursor-agent', chat: true),
        isFalse,
      );
    });

    test('an undescribed or unnamed agent is unknown, not unwatchable', () {
      // The whole point of the catalog: a false here would tell the user a
      // working agent cannot be watched, purely because nobody described it.
      expect(
        handlerObservableFromCatalog(catalog, 'kilo', chat: false),
        isNull,
      );
      expect(handlerObservableFromCatalog(catalog, null, chat: false), isNull);
      expect(
        handlerObservableFromCatalog(const {}, 'opencode', chat: false),
        isNull,
      );
    });
  });

  group('sessionAgentDisplayLabel', () {
    test('names a cached row from the machine-independent catalog', () {
      expect(
        sessionAgentDisplayLabel(_session(tool: 'codex'), {
          'codex': _d('codex', label: 'Codex'),
        }),
        'Codex',
      );
    });

    test('an agent nothing has described renders its raw key', () {
      // Honesty over a guess: the app-side enum this replaced showed such an
      // agent as "Claude Code".
      expect(
        sessionAgentDisplayLabel(_session(tool: 'kilo'), const {}),
        'kilo',
      );
    });

    test('a custom launch command shows the command itself', () {
      expect(
        sessionAgentDisplayLabel(_session(command: 'npm run dev'), const {}),
        'npm run dev',
      );
    });
  });

  group('agentSupportsChatResolved', () {
    test('the target machine advert wins when it spoke', () {
      expect(
        agentSupportsChatResolved(
          const KnownAgent('codex'),
          wireChatCapable: const {'codex'},
          descriptor: _d('codex'),
        ),
        isTrue,
      );
      expect(
        agentSupportsChatResolved(
          const KnownAgent('codex'),
          wireChatCapable: const <String>{},
          descriptor: _d('codex', chatCapable: true),
        ),
        isFalse,
      );
    });

    test('falls back to the catalog when the target said nothing', () {
      expect(
        agentSupportsChatResolved(
          const KnownAgent('codex'),
          wireChatCapable: null,
          descriptor: _d('codex', chatCapable: true),
        ),
        isTrue,
      );
    });

    test('is null when neither the target nor the catalog has said', () {
      expect(
        agentSupportsChatResolved(
          const KnownAgent('kilo'),
          wireChatCapable: null,
          descriptor: null,
        ),
        isNull,
      );
    });

    test('stays unknown for a chat-capable agent nobody has described', () {
      // Guessing `true` from the app's own knowledge is the registry mirror
      // this surface deleted; the caller renders disabled with a reason.
      for (final tool in ['claude-code', 'codex', 'opencode']) {
        expect(
          agentSupportsChatResolved(
            KnownAgent(tool),
            wireChatCapable: null,
            descriptor: null,
          ),
          isNull,
          reason: tool,
        );
      }
    });

    test('a descriptor answers in both directions', () {
      expect(
        agentSupportsChatResolved(
          const KnownAgent('codex'),
          wireChatCapable: null,
          descriptor: _d('codex'),
        ),
        isFalse,
      );
      expect(
        agentSupportsChatResolved(
          const KnownAgent('codex'),
          wireChatCapable: const <String>{},
          descriptor: null,
        ),
        isFalse,
      );
    });

    test('a custom command is false, not unknown', () {
      // No registry entry, so nothing could carry a driver.
      expect(
        agentSupportsChatResolved(
          const CustomAgent(),
          wireChatCapable: null,
          descriptor: null,
        ),
        isFalse,
      );
    });
  });
}
