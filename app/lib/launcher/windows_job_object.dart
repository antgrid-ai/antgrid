// app/lib/launcher/windows_job_object.dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../util/ab_log.dart';

// Win32 constants. Named here rather than pulled from package:win32 to keep the
// dependency surface at `dart:ffi` + an allocator.
const int _jobObjectExtendedLimitInformation = 9;
const int _jobObjectLimitKillOnJobClose = 0x2000;
const int _processTerminate = 0x0001;
const int _processSetQuota = 0x0100;

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;
  @Uint64()
  external int writeOperationCount;
  @Uint64()
  external int otherOperationCount;
  @Uint64()
  external int readTransferCount;
  @Uint64()
  external int writeTransferCount;
  @Uint64()
  external int otherTransferCount;
}

final class _JobBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;
  @Int64()
  external int perJobUserTimeLimit;
  @Uint32()
  external int limitFlags;
  @IntPtr()
  external int minimumWorkingSetSize;
  @IntPtr()
  external int maximumWorkingSetSize;
  @Uint32()
  external int activeProcessLimit;
  @IntPtr()
  external int affinity;
  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class _JobExtendedLimitInformation extends Struct {
  external _JobBasicLimitInformation basicLimitInformation;
  external _IoCounters ioInfo;
  @IntPtr()
  external int processMemoryLimit;
  @IntPtr()
  external int jobMemoryLimit;
  @IntPtr()
  external int peakProcessMemoryUsed;
  @IntPtr()
  external int peakJobMemoryUsed;
}

typedef _CreateJobObjectC =
    IntPtr Function(Pointer<Void> attributes, Pointer<Uint16> name);
typedef _CreateJobObject = int Function(Pointer<Void>, Pointer<Uint16>);

typedef _SetInformationJobObjectC =
    Int32 Function(
      IntPtr job,
      Int32 infoClass,
      Pointer<Void> info,
      Uint32 length,
    );
typedef _SetInformationJobObject =
    int Function(int, int, Pointer<Void>, int);

typedef _AssignProcessToJobObjectC =
    Int32 Function(IntPtr job, IntPtr process);
typedef _AssignProcessToJobObject = int Function(int, int);

typedef _OpenProcessC =
    IntPtr Function(Uint32 access, Int32 inheritHandle, Uint32 pid);
typedef _OpenProcess = int Function(int, int, int);

typedef _CloseHandleC = Int32 Function(IntPtr handle);
typedef _CloseHandle = int Function(int);

typedef _GetLastErrorC = Uint32 Function();
typedef _GetLastError = int Function();

/// Resolved once per process, not per call: `DynamicLibrary.open` is a
/// `LoadLibrary` with no matching `FreeLibrary`, and the symbol lookups are not
/// free either. Lazy, so none of it runs off Windows — the only entry point
/// returns before touching them.
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final _createJobObject = _kernel32
    .lookupFunction<_CreateJobObjectC, _CreateJobObject>('CreateJobObjectW');
final _setInformationJobObject = _kernel32
    .lookupFunction<_SetInformationJobObjectC, _SetInformationJobObject>(
      'SetInformationJobObject',
    );
final _assignProcessToJobObject = _kernel32
    .lookupFunction<_AssignProcessToJobObjectC, _AssignProcessToJobObject>(
      'AssignProcessToJobObject',
    );
final _openProcess = _kernel32
    .lookupFunction<_OpenProcessC, _OpenProcess>('OpenProcess');
final _closeHandle = _kernel32
    .lookupFunction<_CloseHandleC, _CloseHandle>('CloseHandle');

/// Advisory only. Dart does not guarantee the thread's last-error value
/// survives the trampoline out of the failing call and back in through this
/// one (dart-lang/sdk#38832), so read a logged 0 as "unknown", not "success".
final _getLastError = _kernel32
    .lookupFunction<_GetLastErrorC, _GetLastError>('GetLastError');

/// Kernel handle to the app-lifetime job, or 0 once creation has failed.
///
/// Deliberately never closed: the kill fires when the LAST handle to the job
/// closes, and the only handle is this one — so the sweep is performed by the
/// kernel as it reaps our process, on every exit path including a
/// `TerminateProcess` from the Store installer. Any teardown we could write
/// here would run on exactly the paths that already work.
int _job = -1;

/// Puts [pid] and everything it later spawns under a job object that the kernel
/// kills when THIS process dies, however it dies.
///
/// The bridge host outlives a force-kill of the app: `didRequestAppExit` never
/// fires, and `owner-watchdog.ts` only notices ~2s later and then drains
/// gracefully for up to 5s more. On an MSIX build every one of those survivors
/// is a member of the package's Desktop AppX silo, and a silo with live members
/// while the Store destages the package leaks the Helium registry hives —
/// after which no launch of the package succeeds until the user signs out —
/// the silo-leak bullet in the root CLAUDE.md has the full mechanism.
///
/// Measured on Windows 11 26200: a nested job inside a silo is permitted, and
/// KILL_ON_JOB_CLOSE sweeps grandchildren (the PTY trees), leaving the silo
/// drained the instant the app dies.
///
/// Best-effort by design — a failure here costs us the hard backstop, not the
/// soft one, so it is logged and swallowed. No-op off Windows: Linux and macOS
/// have no equivalent that survives SIGKILL of the parent, and the watchdog
/// remains the only backstop there.
///
/// Returns whether [pid] is now a job member — false off Windows and on every
/// failure. Callers ignore it; it is what makes the enclosure assertable.
bool encloseInAppLifetimeJob(int pid) {
  if (!Platform.isWindows) return false;
  try {
    final job = _ensureJob();
    if (job == 0) return false;

    // AssignProcessToJobObject wants exactly these two rights, no more.
    final process = _openProcess(_processTerminate | _processSetQuota, 0, pid);
    if (process == 0) {
      _warn('OpenProcess failed', pid, _getLastError());
      return false;
    }
    try {
      if (_assignProcessToJobObject(job, process) == 0) {
        _warn('AssignProcessToJobObject failed', pid, _getLastError());
        return false;
      }
      AbLog.info(
        'HostController',
        'host enclosed in app-lifetime job',
        fields: {'pid': pid},
      );
      return true;
    } finally {
      _closeHandle(process);
    }
  } catch (e) {
    AbLog.warn(
      'HostController',
      'job-object enclosure unavailable',
      fields: {'pid': pid, 'error': '$e'},
    );
    return false;
  }
}

/// Byte size the kernel expects for `JobObjectExtendedLimitInformation` on
/// 64-bit Windows. Exposed so a test can pin the hand-written struct layout:
/// `SetInformationJobObject` validates the length against the info class, so a
/// drifted layout fails at runtime with nothing but a swallowed warning.
@visibleForTesting
int get jobExtendedLimitInformationSize =>
    sizeOf<_JobExtendedLimitInformation>();

/// One job for the whole app run — every host spawn joins it. Returns 0 once
/// creation or configuration has failed, so the failure is reported once.
int _ensureJob() {
  if (_job != -1) return _job;

  // Unnamed: a named job would be shared across concurrent app instances, and
  // the first one to exit would kill the others' hosts.
  final job = _createJobObject(nullptr, nullptr);
  if (job == 0) {
    _warn('CreateJobObject failed', null, _getLastError());
    return _job = 0;
  }

  final info = calloc<_JobExtendedLimitInformation>();
  try {
    info.ref.basicLimitInformation.limitFlags = _jobObjectLimitKillOnJobClose;
    final ok = _setInformationJobObject(
      job,
      _jobObjectExtendedLimitInformation,
      info.cast<Void>(),
      sizeOf<_JobExtendedLimitInformation>(),
    );
    if (ok == 0) {
      // Leaving a job without KILL_ON_JOB_CLOSE in place would be worse than
      // none: members would be silently confined with nothing reaping them.
      _warn('SetInformationJobObject failed', null, _getLastError());
      _closeHandle(job);
      return _job = 0;
    }
  } finally {
    calloc.free(info);
  }
  return _job = job;
}

void _warn(String what, int? pid, int err) => AbLog.warn(
  'HostController',
  what,
  fields: {'pid': ?pid, 'lastError': err},
);
