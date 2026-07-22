import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_config.dart';

void main() {
  test('round-trips full config through json', () {
    const cfg = AbConfig(
      agent: AbAgentBlock(tool: 'claude-code', flags: ['--yes']),
      services: [AbService(name: 'dev', command: 'npm run dev')],
      commands: [AbCommand(name: 'Test', command: 'bun test', confirm: true)],
      ports: [AbPort(port: 3000, onDetect: OnDetect.notify)],
    );
    final json = cfg.toJson();
    final back = AbConfig.fromJson(json);
    expect(back.agent?.tool, 'claude-code');
    expect(back.services.first.name, 'dev');
    expect(back.commands.first.confirm, true);
    expect(back.ports.first.port, 3000);
  });

  test('omits empty optional lists from json', () {
    const cfg = AbConfig(agent: AbAgentBlock(tool: 'claude-code'));
    final json = cfg.toJson();
    expect(json.containsKey('services'), false);
    expect(json.containsKey('commands'), false);
    expect(json.containsKey('ports'), false);
  });

  test('parses port shorthand (bare number)', () {
    final cfg = AbConfig.fromJson({
      'ports': [
        3000,
        {'port': 4000, 'onDetect': 'notify'},
      ],
    });
    expect(cfg.ports.length, 2);
    expect(cfg.ports[0].port, 3000);
    expect(cfg.ports[1].port, 4000);
  });
}
