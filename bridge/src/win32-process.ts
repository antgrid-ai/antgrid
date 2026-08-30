import { dlopen, FFIType, ptr, type Pointer } from "bun:ffi";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { logger } from "./logger";

const log = logger.child({ component: "win32-process" });

/**
 * The Win32 primitives the checkout teardown needs and `taskkill` cannot give
 * it. Two capabilities, one reason: a process the coding agent started inside a
 * managed checkout routinely outlives its PTY and becomes an ORPHAN, and
 * Windows refuses to delete a directory that is any live process's current
 * directory — which is how `git worktree remove` leaves an isolated session
 * permanently undeletable.
 *
 * `killProcessTree` (`terminal-session.ts`) walks the LIVE parent-child table
 * from a pid, so an orphan is unreachable by construction: its parent is gone
 * and there is no tree left to walk. Job membership is inherited at
 * `CreateProcess` and SURVIVES the parent's death, so a job reaches exactly the
 * processes a parent-link walk cannot.
 *
 * Everything here is an inert no-op off Windows, and best-effort on it: if
 * `dlopen` or any symbol lookup fails the module reports itself unavailable
 * forever after and callers keep the behaviour they had before it existed. A
 * failure must never throw into a spawn path.
 */

// Win32 constants, named here rather than pulled from a package to keep the
// dependency surface at `bun:ffi`.
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
const JobObjectExtendedLimitInformation = 9;
const PROCESS_TERMINATE = 0x0001;
const PROCESS_QUERY_INFORMATION = 0x0400;
const PROCESS_VM_READ = 0x0010;
const PROCESS_SET_QUOTA = 0x0100;
const TH32CS_SNAPPROCESS = 0x0002;
const ProcessBasicInformation = 0;
const STATUS_SUCCESS = 0;

/**
 * `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` on x64, laid out field by field so the
 * two numbers that matter are self-evident:
 *
 *   JOBOBJECT_BASIC_LIMIT_INFORMATION   0..64   (LimitFlags is its 3rd field,
 *     PerProcessUserTimeLimit  0  (LARGE_INTEGER)   at 8+8 = 16)
 *     PerJobUserTimeLimit      8  (LARGE_INTEGER)
 *     LimitFlags              16  (DWORD)
 *     Min/MaxWorkingSetSize   24, 32  (SIZE_T, 8-aligned)
 *     ActiveProcessLimit      40  (DWORD)
 *     Affinity                48  (ULONG_PTR, 8-aligned)
 *     Priority/SchedulingClass 56, 60  (DWORD)
 *   IO_COUNTERS                        64..112  (6 x ULONGLONG)
 *   Process/JobMemoryLimit, peaks     112..144  (4 x SIZE_T)
 *
 * `SetInformationJobObject` validates the length against the info class, so a
 * drifted size fails with ERROR_BAD_LENGTH rather than corrupting anything —
 * `win32-process.test.ts` pins both by asserting the call succeeds.
 */
const JOB_EXTENDED_LIMIT_INFORMATION_SIZE = 144;
const JOB_LIMIT_FLAGS_OFFSET = 16;

/**
 * `PROCESSENTRY32W` on x64: `dwSize` 0, `th32ProcessID` 8, `szExeFile` 44
 * (MAX_PATH wchars = 520 bytes, so the struct ends at 564 and pads to 568 for
 * the 8-byte `th32DefaultHeapID` at 16). `Process32FirstW` fails outright if
 * `dwSize` does not match, so the size is checked by the kernel too.
 */
const PROCESSENTRY32W_SIZE = 568;
const PROCESSENTRY32W_PID_OFFSET = 8;
/** `th32ParentProcessID`, between `cntThreads` (28) and `pcPriClassBase` (36).
 *  Windows never re-parents an orphan, so this keeps naming the original parent
 *  long after that parent has exited — which is what makes it usable as an
 *  identity check for a pid that might since have been recycled. */
const PROCESSENTRY32W_PARENT_OFFSET = 32;
const PROCESSENTRY32W_NAME_OFFSET = 44;
const PROCESSENTRY32W_NAME_MAX_CHARS = 260;

/**
 * `PROCESS_BASIC_INFORMATION` on x64: `ExitStatus` 0 (+4 pad),
 * `PebBaseAddress` 8, `AffinityMask` 16, `BasePriority` 24 (+4 pad),
 * `UniqueProcessId` 32, `InheritedFromUniqueProcessId` 40.
 */
const PROCESS_BASIC_INFORMATION_SIZE = 48;
const PBI_PEB_BASE_ADDRESS_OFFSET = 8;

/**
 * The undocumented walk from a PEB to a process's current directory, on x64:
 * `PEB.ProcessParameters` at +0x20, and inside `RTL_USER_PROCESS_PARAMETERS`
 * the `CurrentDirectory.DosPath` UNICODE_STRING at +0x38 (`Length` in BYTES,
 * `Buffer` at +0x40). Verified against a live process on Windows 11 26200; the
 * whole read is best-effort, so a future layout change costs the holder's name
 * in a log line and nothing else.
 */
const PEB_PROCESS_PARAMETERS_OFFSET = 0x20n;
const PARAMS_CURRENT_DIRECTORY_LENGTH_OFFSET = 0x38n;
const PARAMS_CURRENT_DIRECTORY_BUFFER_OFFSET = 0x40n;

/** A DosPath longer than this is a corrupt read, not a path worth chasing. Must
 * stay BELOW 64 KiB to mean anything: the length it guards comes from a
 * `USHORT`, so a ceiling at or above 65535 can never fire and a torn read of
 * `UNICODE_STRING.Length` would decode 64 KiB of garbage. 32 KiB is the NT path
 * limit, which no real current directory reaches. */
const MAX_CURRENT_DIRECTORY_BYTES = 32 * 1024;

const kernel32Symbols = {
  CreateJobObjectW: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
  SetInformationJobObject: {
    args: [FFIType.ptr, FFIType.i32, FFIType.ptr, FFIType.u32],
    returns: FFIType.i32,
  },
  AssignProcessToJobObject: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  OpenProcess: { args: [FFIType.u32, FFIType.i32, FFIType.u32], returns: FFIType.ptr },
  CloseHandle: { args: [FFIType.ptr], returns: FFIType.i32 },
  GetLastError: { args: [], returns: FFIType.u32 },
  CreateToolhelp32Snapshot: { args: [FFIType.u32, FFIType.u32], returns: FFIType.ptr },
  Process32FirstW: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  Process32NextW: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  // lpBaseAddress is a u64 rather than a ptr so a PEB address crosses as an
  // exact BigInt: bun:ffi's `ptr` argument type takes a JS number, which cannot
  // represent every address a 64-bit process may be mapped at.
  ReadProcessMemory: {
    args: [FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.u64, FFIType.ptr],
    returns: FFIType.i32,
  },
} as const;

const ntdllSymbols = {
  NtQueryInformationProcess: {
    args: [FFIType.ptr, FFIType.i32, FFIType.ptr, FFIType.u32, FFIType.ptr],
    returns: FFIType.i32,
  },
} as const;

interface Win32Api {
  kernel32: ReturnType<typeof dlopen<typeof kernel32Symbols>>["symbols"];
}

/** `undefined` = not attempted, `null` = unavailable and already reported. */
let api: Win32Api | null | undefined;
let ntdll: ReturnType<typeof dlopen<typeof ntdllSymbols>>["symbols"] | null | undefined;

/**
 * Resolve the Win32 layer once per process. `dlopen` is a `LoadLibrary` with no
 * matching `FreeLibrary` and the symbol binding is not free either, so this is
 * memoized in both directions: a failure is reported exactly once and answered
 * with `null` forever after, which is what keeps a broken FFI layer from
 * warning on every PTY spawn.
 */
function loadApi(): Win32Api | null {
  if (api !== undefined) return api;
  if (process.platform !== "win32") return (api = null);
  try {
    api = { kernel32: dlopen("kernel32.dll", kernel32Symbols).symbols };
  } catch (err) {
    log.warn("win32 process api unavailable: %s", err);
    api = null;
  }
  return api;
}

/**
 * Loaded apart from kernel32, and only once a holder scan asks for it. The
 * undocumented `Nt*` exports are the ones a hardened or EDR-instrumented host
 * refuses, and nothing on the job path needs them — so folding both libraries
 * into one all-or-nothing load would let a refusal that costs only a diagnostic
 * message silently disable every PTY's job instead.
 */
function loadNtdll(): ReturnType<typeof dlopen<typeof ntdllSymbols>>["symbols"] | null {
  if (ntdll !== undefined) return ntdll;
  if (process.platform !== "win32") return (ntdll = null);
  try {
    ntdll = dlopen("ntdll.dll", ntdllSymbols).symbols;
  } catch (err) {
    log.warn("win32 process inspection unavailable: %s", err);
    ntdll = null;
  }
  return ntdll;
}

/**
 * Whether the Win32 layer loaded. False off Windows and after any load failure,
 * so a caller can say "no job" honestly rather than claiming coverage it does
 * not have.
 */
export function win32ProcessApiAvailable(): boolean {
  return loadApi() !== null;
}

/** The pid is gone, as opposed to the machine refusing us. */
const ERROR_INVALID_PARAMETER = 87;

/**
 * `CreateToolhelp32Snapshot` reports failure with `INVALID_HANDLE_VALUE`, not
 * NULL, so a null check alone walks an invalid handle and then closes it —
 * which raises STATUS_INVALID_HANDLE under a debugger or the strict-handle
 * flag. That all-ones value reaches JS as either -1 or a double past 2^53
 * depending on how the pointer is widened, and a real kernel handle is a small
 * positive integer, so one test refuses both spellings.
 */
function isUsableHandle(handle: Pointer | null): handle is Pointer {
  if (handle === null) return false;
  const value = Number(handle);
  return Number.isSafeInteger(value) && value > 0;
}

/**
 * Reported at `warn` and only once. A refusal is a property of the machine
 * rather than of the terminal that happened to meet it, so per-spawn logging
 * would be noise — but at `debug`, below the default level, a host where the
 * assignment never lands looks identical to one where the fix is working, and
 * the only field symptom of either is a checkout nothing can delete. Those are
 * different bugs with different fixes, so the log has to tell them apart.
 */
let warnedAssignFailure = false;
function warnAssignFailure(detail: Record<string, unknown>): void {
  if (warnedAssignFailure) return;
  warnedAssignFailure = true;
  log.warn(detail, "job assign failed; this PTY's tree falls back to taskkill, which cannot reach orphans");
}

/**
 * Advisory only: bun:ffi does not guarantee the thread's last-error value
 * survives the trampoline out of the failing call and back in through this one,
 * so read a 0 as "unknown", never as "success" — and never as "not the benign
 * case" either, which is why the one-shot warning below refuses to spend itself
 * on an unknown.
 */
function lastError(a: Win32Api): number {
  try {
    return a.kernel32.GetLastError();
  } catch {
    return 0;
  }
}

/**
 * An open handle to a job object configured with
 * `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
 *
 * The kill fires when the LAST handle to the job closes, so the sweep happens
 * even when nothing runs a shutdown path: a force-killed bridge has its handles
 * closed by the kernel as it is reaped, and every member dies with it. That is
 * the case that matters — in the field most bridge lifetimes end without a
 * clean shutdown, so anything that depends on teardown code running has already
 * lost.
 *
 * Not constructible directly; see {@link createKillOnCloseJob}.
 */
export class Win32Job {
  #handle: Pointer | null;

  /** {@link createKillOnCloseJob} is the only construction site that matters: a
   *  handle from anywhere else has not been given the kill-on-close limit this
   *  class's whole contract rests on. */
  constructor(handle: Pointer) {
    this.#handle = handle;
  }

  /** False once {@link close} has run. */
  get open(): boolean {
    return this.#handle !== null;
  }

  /**
   * Put `pid` — and, by inheritance, everything it goes on to spawn — in this
   * job. Returns whether the process is now a member; false for a pid that has
   * already exited, which is ordinary rather than an error.
   *
   * Only DIRECT `CreateProcess` descendants inherit the job. A child launched
   * through `ShellExecute` (a `Start-Process -WindowStyle Hidden`, say) is
   * created by another process entirely and joins that one's job, not ours — so
   * this reaches most of a PTY's tree, never provably all of it.
   */
  assign(pid: number): boolean {
    const a = loadApi();
    if (a === null || this.#handle === null) return false;
    if (!Number.isInteger(pid) || pid <= 0) return false;
    try {
      // AssignProcessToJobObject wants exactly these two rights, no more.
      // Named `target` rather than `process`: this module branches on the Node
      // global's `platform` throughout, and a shadow here would turn the next
      // such guard into a HANDLE read inside a catch that reports it as a Win32
      // failure.
      const target = a.kernel32.OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, pid);
      if (target === null) {
        // A pid that no longer names a process answers ERROR_INVALID_PARAMETER,
        // which is the ordinary race with a PTY that exited before its own
        // spawn returned — not a machine refusing the assignment. An UNKNOWN
        // (0, see `lastError`) is read the same way: the benign race is by far
        // the likelier reading, and spending the one-shot warning on it would
        // silence every genuine refusal that machine goes on to make.
        const code = lastError(a);
        if (code === ERROR_INVALID_PARAMETER || code === 0) {
          log.debug({ pid, lastError: code }, "job assign: pid unavailable");
        } else {
          warnAssignFailure({ pid, at: "OpenProcess", lastError: code });
        }
        return false;
      }
      try {
        if (a.kernel32.AssignProcessToJobObject(this.#handle, target) === 0) {
          warnAssignFailure({ pid, at: "AssignProcessToJobObject", lastError: lastError(a) });
          return false;
        }
        return true;
      } finally {
        a.kernel32.CloseHandle(target);
      }
    } catch (err) {
      warnAssignFailure({ pid, err: String(err) });
      return false;
    }
  }

  /**
   * Close the handle, which kills every member still running — orphans
   * included. Idempotent, so a teardown path that is reached twice does not
   * close a handle value the kernel may already have reissued to someone else.
   */
  close(): void {
    const handle = this.#handle;
    if (handle === null) return;
    this.#handle = null;
    const a = loadApi();
    if (a === null) return;
    try {
      a.kernel32.CloseHandle(handle);
    } catch (err) {
      log.debug({ err: String(err) }, "job close failed");
    }
  }
}

/**
 * Create an unnamed kill-on-close job, or `null` off Windows and on any
 * failure.
 *
 * Unnamed on purpose: a named job would be shared across concurrent bridges,
 * and the first one to exit would sweep the others' checkouts.
 *
 * A job whose limit could not be set is worse than no job at all — its members
 * would be confined with nothing ever reaping them — so a failed
 * `SetInformationJobObject` closes the handle and answers `null`.
 */
export function createKillOnCloseJob(): Win32Job | null {
  const a = loadApi();
  if (a === null) return null;
  try {
    const handle = a.kernel32.CreateJobObjectW(null, null);
    if (handle === null) {
      log.warn({ lastError: lastError(a) }, "CreateJobObject failed");
      return null;
    }
    const info = new Uint8Array(JOB_EXTENDED_LIMIT_INFORMATION_SIZE);
    new DataView(info.buffer).setUint32(
      JOB_LIMIT_FLAGS_OFFSET,
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
      true,
    );
    const ok = a.kernel32.SetInformationJobObject(
      handle,
      JobObjectExtendedLimitInformation,
      ptr(info),
      JOB_EXTENDED_LIMIT_INFORMATION_SIZE,
    );
    if (ok === 0) {
      log.warn({ lastError: lastError(a) }, "SetInformationJobObject failed");
      a.kernel32.CloseHandle(handle);
      return null;
    }
    return new Win32Job(handle);
  } catch (err) {
    log.warn("kill-on-close job unavailable: %s", err);
    return null;
  }
}

/** One live process, as a Toolhelp snapshot describes it. */
export interface ProcessIdentity {
  readonly pid: number;
  /** `th32ParentProcessID` — the pid that created it, alive or not. */
  readonly parentPid: number;
  /** Image name as Toolhelp reports it, e.g. `bun.exe`. */
  readonly name: string;
}

/** Every live process, or null when the Win32 layer is unavailable — which is
 *  a different answer from "the machine is running nothing". */
function enumerateProcesses(): ProcessIdentity[] | null {
  const a = loadApi();
  if (a === null) return null;
  let snapshot: Pointer | null = null;
  try {
    snapshot = a.kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (!isUsableHandle(snapshot)) return null;
    const entry = new Uint8Array(PROCESSENTRY32W_SIZE);
    const view = new DataView(entry.buffer);
    view.setUint32(0, PROCESSENTRY32W_SIZE, true);
    const all: ProcessIdentity[] = [];
    let more = a.kernel32.Process32FirstW(snapshot, ptr(entry));
    // A live machine never runs zero processes, so a first call that fails —
    // ERROR_BAD_LENGTH is the documented transient — is unknowable, and
    // falling through to the empty array below would report it as "nothing is
    // running", which every caller reads as "the tree is gone".
    if (more === 0) return null;
    while (more !== 0) {
      all.push({
        pid: view.getUint32(PROCESSENTRY32W_PID_OFFSET, true),
        parentPid: view.getUint32(PROCESSENTRY32W_PARENT_OFFSET, true),
        name: readEntryName(view),
      });
      view.setUint32(0, PROCESSENTRY32W_SIZE, true);
      more = a.kernel32.Process32NextW(snapshot, ptr(entry));
    }
    return all;
  } catch (err) {
    log.debug({ err: String(err) }, "process enumeration failed");
    return null;
  } finally {
    if (isUsableHandle(snapshot)) {
      try {
        a.kernel32.CloseHandle(snapshot);
      } catch {
        // Advisory path; a handle the kernel already rejected is nothing to report.
      }
    }
  }
}

/**
 * Everything `rootPid` has started, transitively, as of right now.
 *
 * Taken BEFORE a graceful ask, and that timing is the whole point. Asking a
 * leader to exit destroys the parent links `taskkill /T` walks — the survivors
 * are re-parented to nothing and the walk has no route to them — and the PTY's
 * kill-on-close job does not close that gap on its own: a child created through
 * `ShellExecute` joins its creator's job, not ours. A snapshot taken while the
 * tree is still whole is the only reach that survives the leader leaving.
 *
 * Null when the snapshot could not be taken — including off Windows, where
 * `loadApi` answers null. An empty array means the leader started nothing; the
 * two must stay distinguishable, because a caller that cannot take the
 * snapshot has lost the only reach a departing leader leaves behind and owes
 * itself a decision, not a silent no-op.
 */
export function snapshotDescendants(rootPid: number): ProcessIdentity[] | null {
  if (!Number.isInteger(rootPid) || rootPid <= 0) return null;
  const all = enumerateProcesses();
  if (all === null) return null;
  const byParent = new Map<number, ProcessIdentity[]>();
  for (const p of all) {
    // A process reporting itself as its own parent (pid 0 does) would otherwise
    // make the walk below never terminate.
    if (p.parentPid === p.pid) continue;
    const siblings = byParent.get(p.parentPid);
    if (siblings) siblings.push(p);
    else byParent.set(p.parentPid, [p]);
  }
  const found: ProcessIdentity[] = [];
  const seen = new Set<number>([rootPid]);
  const queue = [rootPid];
  while (queue.length > 0) {
    for (const child of byParent.get(queue.shift()!) ?? []) {
      if (seen.has(child.pid)) continue;
      seen.add(child.pid);
      found.push(child);
      queue.push(child.pid);
    }
  }
  return found;
}

/**
 * Which of `entries` are still the SAME processes.
 *
 * A pid alone cannot answer that: by the time a grace period has elapsed the
 * process may be gone and Windows may have reissued its pid, and killing a
 * recycled pid kills a stranger's process tree. The parent pid and the image
 * name are recorded at snapshot time and neither changes for the life of a
 * process — Windows leaves the parent field pointing at the original creator
 * even after it exits — so a match on all three is identity, not coincidence.
 *
 * Null when the answer is unknowable. "All still alive" would be the safe
 * reading for a caller that is only WAITING, and "all gone" the safe reading
 * for one that is about to KILL; there is no single array that serves both, so
 * neither is invented here.
 */
export function survivingProcesses(
  entries: readonly ProcessIdentity[],
): ProcessIdentity[] | null {
  if (entries.length === 0) return [];
  const all = enumerateProcesses();
  if (all === null) return null;
  const wanted = new Set(entries.map((p) => p.pid));
  const live = new Map<number, ProcessIdentity>();
  for (const p of all) if (wanted.has(p.pid)) live.set(p.pid, p);
  return entries.filter((want) => {
    const now = live.get(want.pid);
    return now !== undefined && now.parentPid === want.parentPid && now.name === want.name;
  });
}

/** A live process holding a directory as its current directory. */
export interface DirectoryHolder {
  readonly pid: number;
  /** Image name as Toolhelp reports it, e.g. `bun.exe`. */
  readonly name: string;
  /** The process's current directory, as the kernel spells it. */
  readonly cwd: string;
}

/**
 * Every live process whose current directory is `root` or lies under it.
 *
 * This runs on a failure path — a delete Windows refused — and exists to NAME
 * the holder, so it never throws and never reports a partial read as an error:
 * a process this one cannot open is skipped silently, which is the normal
 * answer for anything running as another user or as a protected process.
 *
 * Empty off Windows, on a load failure, and when nothing holds the directory —
 * the three are deliberately indistinguishable to callers, because none of them
 * is a reason to do anything different.
 */
export function listProcessesWithCwdUnder(root: string): DirectoryHolder[] {
  const a = loadApi();
  if (a === null) return [];
  const prefixes = comparablePrefixes(root);
  if (prefixes.length === 0) return [];

  const held: DirectoryHolder[] = [];
  let snapshot: Pointer | null = null;
  try {
    snapshot = a.kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (!isUsableHandle(snapshot)) return [];
    // Per call rather than per module: cheap, and it keeps two concurrent
    // callers from ever sharing a scratch buffer.
    const entry = new Uint8Array(PROCESSENTRY32W_SIZE);
    const entryView = new DataView(entry.buffer);
    entryView.setUint32(0, PROCESSENTRY32W_SIZE, true);
    let more = a.kernel32.Process32FirstW(snapshot, ptr(entry));
    while (more !== 0) {
      const pid = entryView.getUint32(PROCESSENTRY32W_PID_OFFSET, true);
      const cwd = readProcessCurrentDirectory(a, pid);
      if (cwd !== null && isUnderAny(normalizePath(cwd), prefixes)) {
        held.push({ pid, name: readEntryName(entryView), cwd: stripTrailingSeparators(cwd) });
      }
      entryView.setUint32(0, PROCESSENTRY32W_SIZE, true);
      more = a.kernel32.Process32NextW(snapshot, ptr(entry));
    }
  } catch (err) {
    log.debug({ err: String(err) }, "cwd holder enumeration failed");
  } finally {
    if (isUsableHandle(snapshot)) {
      try {
        a.kernel32.CloseHandle(snapshot);
      } catch {
        // Nothing to do about a handle the kernel already rejected, and this
        // whole function answers a question that is only ever advisory.
      }
    }
  }
  return held;
}

/** `null` for every process this one may not open or read — the common case. */
function readProcessCurrentDirectory(a: Win32Api, pid: number): string | null {
  if (pid <= 0) return null;
  const nt = loadNtdll();
  if (nt === null) return null;
  let handle: Pointer | null = null;
  try {
    handle = a.kernel32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, 0, pid);
    if (handle === null) return null;

    const pbi = new Uint8Array(PROCESS_BASIC_INFORMATION_SIZE);
    if (
      nt.NtQueryInformationProcess(
        handle,
        ProcessBasicInformation,
        ptr(pbi),
        PROCESS_BASIC_INFORMATION_SIZE,
        null,
      ) !== STATUS_SUCCESS
    ) {
      return null;
    }
    const peb = new DataView(pbi.buffer).getBigUint64(PBI_PEB_BASE_ADDRESS_OFFSET, true);
    if (peb === 0n) return null;

    const params = readU64(a, handle, peb + PEB_PROCESS_PARAMETERS_OFFSET);
    if (params === null || params === 0n) return null;

    const lengthBytes = readU16(a, handle, params + PARAMS_CURRENT_DIRECTORY_LENGTH_OFFSET);
    if (lengthBytes === null || lengthBytes === 0 || lengthBytes > MAX_CURRENT_DIRECTORY_BYTES) {
      return null;
    }
    const buffer = readU64(a, handle, params + PARAMS_CURRENT_DIRECTORY_BUFFER_OFFSET);
    if (buffer === null || buffer === 0n) return null;

    // Length is in bytes and the path is UTF-16 — an odd count is a torn read.
    if (lengthBytes % 2 !== 0) return null;
    const path = new Uint8Array(lengthBytes);
    if (!readMemory(a, handle, buffer, path)) return null;
    return new TextDecoder("utf-16le").decode(path);
  } catch {
    return null;
  } finally {
    if (handle !== null) {
      try {
        a.kernel32.CloseHandle(handle);
      } catch {
        // See the snapshot handle above: advisory path, nothing to report.
      }
    }
  }
}

function readMemory(a: Win32Api, handle: Pointer, address: bigint, out: Uint8Array): boolean {
  return (
    a.kernel32.ReadProcessMemory(handle, address, ptr(out), BigInt(out.length), null) !== 0
  );
}

function readU64(a: Win32Api, handle: Pointer, address: bigint): bigint | null {
  const out = new Uint8Array(8);
  if (!readMemory(a, handle, address, out)) return null;
  return new DataView(out.buffer).getBigUint64(0, true);
}

function readU16(a: Win32Api, handle: Pointer, address: bigint): number | null {
  const out = new Uint8Array(2);
  if (!readMemory(a, handle, address, out)) return null;
  return new DataView(out.buffer).getUint16(0, true);
}

/** `szExeFile` is a fixed-width NUL-terminated WCHAR array, not a length-prefixed string. */
function readEntryName(entry: DataView): string {
  let name = "";
  for (let i = 0; i < PROCESSENTRY32W_NAME_MAX_CHARS; i++) {
    const code = entry.getUint16(PROCESSENTRY32W_NAME_OFFSET + i * 2, true);
    if (code === 0) break;
    name += String.fromCharCode(code);
  }
  return name;
}

/**
 * Comparison form for Windows paths: separators unified, case folded, trailing
 * separators dropped. The kernel hands back a current directory with a trailing
 * backslash, and the path a caller passes in has none.
 */
function normalizePath(path: string): string {
  return stripTrailingSeparators(path.replace(/\//g, "\\")).toLowerCase();
}

function stripTrailingSeparators(path: string): string {
  return path.replace(/[\\/]+$/, "");
}

/** The directory itself counts as held — it is the one Git deletes last. */
function isUnder(candidate: string, prefix: string): boolean {
  return candidate === prefix || candidate.startsWith(`${prefix}\\`);
}

function isUnderAny(candidate: string, prefixes: readonly string[]): boolean {
  return prefixes.some((prefix) => isUnder(candidate, prefix));
}

/**
 * Every spelling of `root` a holder's own current directory may be recorded
 * under.
 *
 * The kernel reports whatever path the process was given, so the two sides are
 * spelled differently by construction: a checkout row carries a realpath, while
 * the reconcile sweep derives its roots from `abDir` verbatim — reach `abDir`
 * through a junction or a symlinked home and a single-spelling compare names no
 * holder at all, which reads exactly like "nothing was holding it" on the one
 * path that exists to say otherwise. Same realpath-and-fold rule as `canonical`
 * in `worktree-manager.ts`, applied to both spellings rather than one, because
 * only the caller's side can be canonicalized cheaply.
 */
function comparablePrefixes(root: string): string[] {
  const spellings = new Set<string>();
  for (const spelling of [() => resolve(root), () => realpathSync.native(root)]) {
    try {
      const normalized = normalizePath(spelling());
      if (normalized !== "") spellings.add(normalized);
    } catch {
      // A root that cannot be resolved or no longer exists contributes no
      // spelling; the other one still answers.
    }
  }
  return [...spellings];
}
