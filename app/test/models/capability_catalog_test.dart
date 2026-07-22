import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/models/capability_catalog.dart';

AgentCapabilities _caps({
  bool ready = true,
  List<AgentCapabilityModel> models = const [],
  String? currentModelId,
}) => AgentCapabilities(
      sessionId: 's1',
      ready: ready,
      models: models,
      modes: const [AgentCapabilityMode(id: 'plan', name: 'Plan')],
      commands: const [AgentCapabilityCommand(id: 'init', name: '/init')],
      currentModelId: currentModelId,
      currentEffortId: 'high',
    );

const _model = AgentCapabilityModel(
  id: 'opus',
  name: 'Opus',
  efforts: ['low', 'high'],
  defaultEffort: 'high',
);

void main() {
  group('CapabilityCatalog', () {
    test('fromCapabilities keeps catalog, drops current* ids', () {
      final cat = CapabilityCatalog.fromCapabilities(
        _caps(models: const [_model], currentModelId: 'opus'),
      );
      expect(cat.models.single.id, 'opus');
      expect(cat.modes.single.id, 'plan');
      expect(cat.commands.single.id, 'init');
      // No field on the catalog can carry a selection id.
      expect(cat.toJson().containsKey('currentModelId'), isFalse);
    });

    test('isEmpty is true only with no models, modes, commands', () {
      expect(const CapabilityCatalog().isEmpty, isTrue);
      expect(
        const CapabilityCatalog(models: [_model]).isEmpty,
        isFalse,
      );
    });

    test('toJson/fromJson round-trip preserves efforts', () {
      final cat = CapabilityCatalog.fromCapabilities(
        _caps(models: const [_model]),
      );
      final back = CapabilityCatalog.fromJson(cat.toJson());
      expect(back.models.single.efforts, ['low', 'high']);
      expect(back.models.single.defaultEffort, 'high');
      expect(back.modes.single.name, 'Plan');
      expect(back.commands.single.name, '/init');
    });

    test('fromJson tolerates missing/garbage lists', () {
      final cat = CapabilityCatalog.fromJson(const {'models': 'nope'});
      expect(cat.isEmpty, isTrue);
    });

    test('fromJson parses Map<dynamic,dynamic> entries, not just typed maps', () {
      // A list carrying an untyped map (e.g. from a test fixture or a non-
      // jsonDecode source) must still be parsed, not silently dropped.
      final raw = <String, dynamic>{
        'models': <dynamic>[<dynamic, dynamic>{'id': 'opus', 'name': 'Opus'}],
      };
      final cat = CapabilityCatalog.fromJson(raw);
      expect(cat.models.single.id, 'opus');
    });
  });

  group('resolveComposerCapabilities', () {
    final cached = CapabilityCatalog.fromCapabilities(
      _caps(models: const [_model]),
    );

    test('live ready + non-empty wins unchanged', () {
      final live = _caps(models: const [_model], currentModelId: 'opus');
      expect(
        resolveComposerCapabilities(live: live, cached: cached),
        same(live),
      );
    });

    test('live ready + empty models wins — stale cache NOT resurrected', () {
      // A ready frame is authoritative: empty means the machine offers nothing,
      // so the cached catalog must not be overlaid under it.
      final live = _caps(ready: true, models: const []);
      expect(
        resolveComposerCapabilities(live: live, cached: cached),
        same(live),
      );
    });

    test('live loading + cache → merged, ready, live current ids retained', () {
      final live = _caps(ready: false, models: const [], currentModelId: 'opus');
      final merged = resolveComposerCapabilities(live: live, cached: cached)!;
      expect(merged.ready, isTrue);
      expect(merged.models.single.id, 'opus');
      expect(merged.currentModelId, 'opus');
      expect(merged.currentEffortId, 'high');
    });

    test('live null + cache → merged from cache', () {
      final merged = resolveComposerCapabilities(live: null, cached: cached)!;
      expect(merged.ready, isTrue);
      expect(merged.models.single.id, 'opus');
      expect(merged.currentModelId, isNull);
    });

    test('live null + no/empty cache → null', () {
      expect(resolveComposerCapabilities(live: null, cached: null), isNull);
      expect(
        resolveComposerCapabilities(
          live: null,
          cached: const CapabilityCatalog(),
        ),
        isNull,
      );
    });
  });
}
