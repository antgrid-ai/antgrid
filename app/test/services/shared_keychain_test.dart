import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/shared_keychain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ai.radhaai.antgrid/keychain');

  test('write/read/delete round-trip through the channel', () async {
    final store = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map).cast<String, dynamic>();
          switch (call.method) {
            case 'write':
              store[args['key'] as String] = args['value'] as String;
              return null;
            case 'read':
              return store[args['key'] as String];
            case 'delete':
              store.remove(args['key'] as String);
              return null;
          }
          return null;
        });
    final kc = SharedKeychain();
    await kc.write('k', 'v');
    expect(await kc.read('k'), 'v');
    await kc.delete('k');
    expect(await kc.read('k'), isNull);
  });
}
