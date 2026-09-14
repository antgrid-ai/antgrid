// The add-machine dialog's project pre-selection. Both sides are already the
// bridge's normalised remote, so what is left to get wrong is which candidate
// wins and, more importantly, when nothing should.
import 'package:antgrid/util/git_remote_match.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('picks the candidate whose repository is the lead\'s', () {
    expect(
      preselectProjectByRemote(
        leadRemote: 'github.com/acme/app',
        candidateRemotes: const {
          'other': 'github.com/acme/other',
          'app': 'github.com/acme/app',
          'fork': 'github.com/someone/app',
        },
      ),
      'app',
    );
  });

  test('answers in the order the dropdown renders', () {
    // Two clones of one repo on a machine both match; the pre-selection has to
    // land on the row the user would have reached first.
    expect(
      preselectProjectByRemote(
        leadRemote: 'github.com/acme/app',
        candidateRemotes: const {
          'app': 'github.com/acme/app',
          'app-copy': 'github.com/acme/app',
        },
      ),
      'app',
    );
  });

  test('a lead with no remote matches nothing', () {
    // The dangerous case: a null key compared loosely would match every
    // candidate that also has none, i.e. every non-repo folder on the machine.
    expect(
      preselectProjectByRemote(
        leadRemote: null,
        candidateRemotes: const {'a': null, 'b': 'github.com/acme/app'},
      ),
      isNull,
    );
    expect(
      preselectProjectByRemote(
        leadRemote: '',
        candidateRemotes: const {'a': null},
      ),
      isNull,
    );
  });

  test('candidates with no remote of their own are skipped', () {
    expect(
      preselectProjectByRemote(
        leadRemote: 'github.com/acme/app',
        candidateRemotes: const {
          'blank': null,
          'empty': '',
          'app': 'github.com/acme/app',
        },
      ),
      'app',
    );
  });

  test('no match is an answer, not a fallback to the first candidate', () {
    expect(
      preselectProjectByRemote(
        leadRemote: 'github.com/acme/app',
        candidateRemotes: const {'other': 'github.com/acme/other'},
      ),
      isNull,
    );
    expect(
      preselectProjectByRemote(
        leadRemote: 'github.com/acme/app',
        candidateRemotes: const {},
      ),
      isNull,
    );
  });
}
