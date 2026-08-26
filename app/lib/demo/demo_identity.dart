import '../models/ab_project.dart';

/// Identity of the built-in offline demo workspace.
///
/// Demo mode drives the REAL workspace UI from canned frames, so the demo
/// project flows through every provider a live project does. These constants
/// are the single discriminator those providers gate on — anything that would
/// persist, phone home, or reach the keychain checks [isDemoProjectId] first.

/// Project id the demo transport is registered under.
///
/// Not a legal bridge project id (a real one is a hashed absolute path), so it
/// can never collide with a machine the user actually owns.
const String kDemoProjectId = 'antgrid-demo';

/// Human name shown wherever the workspace names its project. Carries the
/// "(sample)" suffix so a screenshot of the demo is self-labelling even without
/// the surrounding banner.
const String kDemoDisplayName = 'demo-shop (sample)';

bool isDemoProjectId(String? projectId) => projectId == kDemoProjectId;

/// Cache/registry keys are the project id for a local session, so the two
/// predicates coincide today. Kept separate because a store keyed by the relay
/// `registrationId` would need the suffix match, and callers should not have to
/// know which kind of key they hold.
bool isDemoEntryId(String? entryId) =>
    entryId == kDemoProjectId ||
    (entryId?.endsWith('.$kDemoProjectId') ?? false);

/// Machine-readable refusal for anything the demo cannot honestly do, and the
/// one sentence every surface says when it declines. Lives here rather than in
/// `demo_transport.dart` because the refusal is not only a wire answer: an
/// affordance the UI resolves without ever asking the transport (the preview's
/// port list, say) must decline in the same words.
const String kDemoRefusalCode = 'E_DEMO_UNSUPPORTED';
const String kDemoRefusalText =
    'This is the sample project — connect a machine to do that for real.';

/// Label on every affordance that opens the demo (sign-in, the desktop setup
/// checklist, the Recent tab's empty state). One definition because it is the
/// same promise in each place, and a reviewer meeting two wordings would read
/// them as two different things.
const String kDemoEntryLabel = 'Explore a sample project';

/// Folder the sample project claims to live in. Shown as the drawer row's
/// subtitle and in the picker's detail column; never touched on disk.
const String kDemoFolder = '~/code/demo-shop';

/// The sample project as the rest of the app expects to receive it.
///
/// One definition, because two surfaces list projects from independent sources
/// (the drawer's [DrawerEntry] merge and the New Session picker's rail) and a
/// demo that named itself differently in each would look like two projects.
/// Built fresh per call rather than held as a const: [AbProject] carries
/// mutable fields, and a shared instance would let one surface's write reach
/// the other.
AbProject demoProject() => AbProject(
  projectId: kDemoProjectId,
  folder: kDemoFolder,
  displayName: kDemoDisplayName,
  // Never persisted (the demo is exempt from every store), so the fields a real
  // project carries for host routing have nothing to say here.
  hostDeviceUuid: null,
  hostMachineName: '',
  // Now, not the epoch: the New Session picker copies this straight into
  // `PickerProject.lastActiveAt` and renders it, where a zero read as the
  // sample project having last been opened in 1970.
  lastOpenedAt: DateTime.now(),
);
