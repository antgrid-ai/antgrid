import 'package:antgrid/config/build_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source URL pins a release commit and falls back for development', () {
    const sha = '0123456789abcdef0123456789abcdef01234567';

    expect(
      BuildInfo.sourceUrlFor(sha),
      'https://github.com/antgrid-ai/antgrid/tree/$sha',
    );
    expect(
      BuildInfo.sourceUrlFor('local'),
      'https://github.com/antgrid-ai/antgrid',
    );
  });
}
