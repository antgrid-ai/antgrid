//! libportable-pty — Cross-platform PTY + process-spawn library.
//!
//! Exposes a C API wrapping the `portable-pty` crate from wezterm.
//! Supports Linux, macOS, Windows (ConPTY), Android, and iOS targets where the
//! platform sandbox permits local process spawning.
//!
//! ## SIGCHLD handling
//!
//! The Dart VM's test runner installs a global `SIGCHLD` handler that calls
//! `waitpid(-1, …)`, reaping **all** child processes — including PTY children
//! spawned by this library. This causes `child.try_wait()` and `child.wait()`
//! to fail with `ECHILD` because the child has already been collected.
//!
//! To solve this, we install our own `SIGCHLD` handler that calls
//! `waitpid(pid, WNOHANG)` for each tracked PTY child **before** chaining to
//! the previous handler (Dart's). Exit statuses are cached in a lock-free
//! global registry using atomics (all operations are async-signal-safe).

#[cfg(unix)]
use libc;
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize, SlavePty};
use std::ffi::{c_char, c_int, CStr};
#[cfg(target_os = "android")]
use std::fs::OpenOptions;
use std::io::{Read, Write};
#[cfg(target_os = "android")]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Mutex;

/// Helper to get the current errno value on Unix platforms.
#[cfg(unix)]
fn get_errno() -> c_int {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

#[cfg(target_os = "android")]
fn normalize_android_pty_termios(master: &Box<dyn MasterPty + Send>) {
    let Some(tty_path) = master.tty_name() else {
        return;
    };

    let Ok(tty) = OpenOptions::new().read(true).write(true).open(&tty_path) else {
        return;
    };

    let fd = tty.as_raw_fd();
    let mut termios = std::mem::MaybeUninit::<libc::termios>::uninit();
    if unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) } != 0 {
        return;
    }
    let mut termios = unsafe { termios.assume_init() };

    termios.c_iflag |= libc::BRKINT | libc::ICRNL | libc::IXON;
    #[cfg(any(target_os = "android", target_os = "linux"))]
    {
        termios.c_iflag |= libc::IUTF8;
    }
    termios.c_oflag |= libc::OPOST | libc::ONLCR;
    termios.c_cflag |= libc::CREAD;
    termios.c_lflag |=
        libc::ECHO | libc::ECHOE | libc::ECHOK | libc::ICANON | libc::IEXTEN | libc::ISIG;
    termios.c_cc[libc::VMIN] = 1;
    termios.c_cc[libc::VTIME] = 0;

    unsafe {
        let _ = libc::tcsetattr(fd, libc::TCSANOW, &termios);
    }
}

// ---------------------------------------------------------------------------
// SIGCHLD handler & PID registry (Unix only)
// ---------------------------------------------------------------------------
//
// We track up to MAX_TRACKED_PIDS children. Each slot is a pair of atomics:
//   - `pid`:    the child PID (0 = unused slot)
//   - `status`: the raw waitpid status, or SLOT_EMPTY / SLOT_RUNNING
//
// The SIGCHLD handler iterates all slots and calls `waitpid(pid, WNOHANG)`
// for each registered PID. If the child has exited, the status is stored
// atomically. All operations use `Relaxed` ordering because signal handlers
// run on the same thread and we only need atomicity, not cross-thread ordering.

#[cfg(unix)]
const MAX_TRACKED_PIDS: usize = 64;

/// Sentinel: slot has no cached status yet (child still running or not checked).
#[cfg(unix)]
const SLOT_RUNNING: i32 = i32::MIN;

/// Sentinel: slot is unused (pid == 0).
#[cfg(unix)]
const SLOT_EMPTY: i32 = i32::MIN + 1;

#[cfg(unix)]
struct PidSlot {
    pid: AtomicI32,
    /// Raw `waitpid` status word, or SLOT_RUNNING / SLOT_EMPTY.
    status: AtomicI32,
}

#[cfg(unix)]
impl PidSlot {
    const fn new() -> Self {
        PidSlot {
            pid: AtomicI32::new(0),
            status: AtomicI32::new(SLOT_EMPTY),
        }
    }
}

// We can't use Vec or HashMap in a signal handler. A fixed-size array of
// atomics is async-signal-safe.
#[cfg(unix)]
static PID_REGISTRY: [PidSlot; MAX_TRACKED_PIDS] = {
    // const array init
    const EMPTY: PidSlot = PidSlot::new();
    [EMPTY; MAX_TRACKED_PIDS]
};

/// Previous SIGCHLD handler action, saved so we can chain to it.
#[cfg(unix)]
static mut PREV_SIGCHLD_ACTION: libc::sigaction = unsafe { std::mem::zeroed() };

/// Flag indicating whether we've installed our handler at least once.
/// We use AtomicI32 instead of Once so we can re-install if Dart overwrites us.
#[cfg(unix)]
static SIGCHLD_INSTALLED: AtomicI32 = AtomicI32::new(0);

/// Register a child PID for SIGCHLD tracking. Must be called after spawn.
#[cfg(unix)]
fn register_pid(pid: i32) {
    ensure_sigchld_handler();
    for slot in PID_REGISTRY.iter() {
        // Try to claim an empty slot (pid == 0).
        if slot
            .pid
            .compare_exchange(0, pid, Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
        {
            slot.status.store(SLOT_RUNNING, Ordering::Relaxed);
            return;
        }
    }
    // All slots full — this PID won't be tracked by SIGCHLD.
    // The ECHILD fallback in portable_pty_wait will still handle it.
}

/// Unregister a child PID (called on close).
#[cfg(unix)]
fn unregister_pid(pid: i32) {
    for slot in PID_REGISTRY.iter() {
        if slot
            .pid
            .compare_exchange(pid, 0, Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
        {
            slot.status.swap(SLOT_EMPTY, Ordering::Relaxed);
            return;
        }
    }
}

/// Look up a cached exit code from the SIGCHLD handler registry.
///
/// Returns `Some(exit_code)` if the handler already captured the child's exit,
/// or `None` if the child is still running (or not tracked).
#[cfg(unix)]
fn lookup_cached_status(pid: i32) -> Option<c_int> {
    for slot in PID_REGISTRY.iter() {
        if slot.pid.load(Ordering::Relaxed) == pid {
            let raw = slot.status.load(Ordering::Relaxed);
            if raw == SLOT_RUNNING || raw == SLOT_EMPTY {
                return None;
            }
            // Decode the raw waitpid status word.
            let code = if libc::WIFEXITED(raw) {
                libc::WEXITSTATUS(raw)
            } else if libc::WIFSIGNALED(raw) {
                128 + libc::WTERMSIG(raw)
            } else {
                -1
            };
            return Some(code);
        }
    }
    None
}

/// The actual SIGCHLD handler. This runs in signal context so only
/// async-signal-safe functions may be called (waitpid, atomic loads/stores).
///
/// The Dart VM has an internal thread that calls `waitpid(-1, 0)` (blocking)
/// to reap ALL child processes. This thread races with our handler's
/// `waitpid(pid, WNOHANG)` calls. To handle this, we FIRST extract the
/// exit status from the `siginfo_t` structure (which is populated by the
/// kernel regardless of whether another thread has already reaped the child),
/// and THEN try `waitpid` for any other registered PIDs that might have
/// exited due to signal coalescing.
#[cfg(unix)]
extern "C" fn sigchld_handler(sig: c_int, info: *mut libc::siginfo_t, ctx: *mut libc::c_void) {
    // Step 1: Extract exit info from siginfo_t. This tells us which PID
    // triggered THIS particular SIGCHLD delivery, and its exit status.
    // This works even if Dart's waitpid thread has already reaped the child.
    if !info.is_null() {
        let si = unsafe { &*info };
        let si_pid = unsafe { si.si_pid() };
        let si_code = si.si_code;
        let si_status = unsafe { si.si_status() };

        if si_pid > 0
            && (si_code == libc::CLD_EXITED
                || si_code == libc::CLD_KILLED
                || si_code == libc::CLD_DUMPED)
        {
            // Convert to a waitpid-style status word so lookup_cached_status
            // can decode it uniformly.
            let raw_status = if si_code == libc::CLD_EXITED {
                // Normal exit: encode as WIFEXITED status word
                (si_status & 0xff) << 8
            } else {
                // Killed by signal: encode as WIFSIGNALED status word
                // If core dumped (CLD_DUMPED), set bit 7
                let core_bit = if si_code == libc::CLD_DUMPED { 0x80 } else { 0 };
                (si_status & 0x7f) | core_bit
            };

            // Store in registry if this PID is tracked.
            for slot in PID_REGISTRY.iter() {
                let slot_pid = slot.pid.load(Ordering::Relaxed);
                if slot_pid == si_pid {
                    // Only store if still SLOT_RUNNING (don't overwrite).
                    let _ = slot.status.compare_exchange(
                        SLOT_RUNNING,
                        raw_status,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    );
                    break;
                }
            }
        }
    }

    // Step 2: Handle signal coalescing — multiple children may have exited
    // but only one SIGCHLD was delivered. Try waitpid for all tracked PIDs
    // that are still marked as SLOT_RUNNING.
    for slot in PID_REGISTRY.iter() {
        let pid = slot.pid.load(Ordering::Relaxed);
        if pid <= 0 {
            continue;
        }
        if slot.status.load(Ordering::Relaxed) != SLOT_RUNNING {
            continue;
        }
        let mut status: c_int = 0;
        let ret = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if ret == pid {
            slot.status.store(status, Ordering::Relaxed);
        }
        // ret == 0: still running. ret == -1: ECHILD (Dart's thread reaped it,
        // but we may have already captured status from siginfo_t above or in
        // a previous signal delivery).
    }

    // Chain to the previous handler.
    unsafe {
        let prev = &*(&raw const PREV_SIGCHLD_ACTION);
        let flags = prev.sa_flags;
        if flags & libc::SA_SIGINFO != 0 {
            // SA_SIGINFO handler: void (*)(int, siginfo_t*, void*)
            let handler = prev.sa_sigaction;
            if handler != libc::SIG_DFL && handler != libc::SIG_IGN {
                let f: extern "C" fn(c_int, *mut libc::siginfo_t, *mut libc::c_void) =
                    std::mem::transmute(handler);
                f(sig, info, ctx);
            }
        } else {
            // Traditional handler: void (*)(int)
            let handler = prev.sa_sigaction;
            if handler != libc::SIG_DFL && handler != libc::SIG_IGN {
                let f: extern "C" fn(c_int) = std::mem::transmute(handler);
                f(sig);
            }
        }
    }
}

/// Install (or re-install) our SIGCHLD handler.
///
/// The Dart VM's test runner may install its own SIGCHLD handler after ours,
/// overwriting it. We check whether the current handler is still ours; if not,
/// we re-install and update the saved previous handler for chaining.
#[cfg(unix)]
fn ensure_sigchld_handler() {
    // Serialize the check-and-install: concurrent spawns race on the
    // non-atomic `PREV_SIGCHLD_ACTION`, and without the lock two threads can
    // both pass the "is it ours?" check and the second reads back the first's
    // just-installed handler as "previous" — saving `sigchld_handler` as PREV,
    // which self-chains into infinite recursion on the next SIGCHLD. Only ever
    // called from spawn context (never the signal handler), so locking is safe.
    static HANDLER_MUTEX: Mutex<()> = Mutex::new(());
    let _guard = HANDLER_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    unsafe {
        // Check what the current handler is.
        let mut current: libc::sigaction = std::mem::zeroed();
        libc::sigaction(libc::SIGCHLD, std::ptr::null(), &mut current);

        if current.sa_sigaction == sigchld_handler as usize {
            // Our handler is still installed — nothing to do.
            return;
        }

        // Either first install or someone overwrote us. (Re-)install.
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = sigchld_handler as usize;
        sa.sa_flags = libc::SA_SIGINFO | libc::SA_RESTART | libc::SA_NOCLDSTOP;
        libc::sigemptyset(&mut sa.sa_mask);

        // Save the current handler (Dart's or whoever overwrote us) for chaining.
        libc::sigaction(libc::SIGCHLD, &sa, &raw mut PREV_SIGCHLD_ACTION);
        SIGCHLD_INSTALLED.store(1, Ordering::Relaxed);
    }
}

// ---------------------------------------------------------------------------
// Result enum
// ---------------------------------------------------------------------------

#[repr(C)]
pub enum PortablePtyResult {
    Ok = 0,
    ErrOpen = 1,
    ErrSpawn = 2,
    ErrResize = 3,
    ErrRead = 4,
    ErrWrite = 5,
    ErrNull = 6,
    ErrWait = 7,
    ErrKill = 8,
    ErrMode = 9,
    ErrSize = 10,
    ErrWaitBlocking = 11,
    ErrProcessGroup = 12,
}

// ---------------------------------------------------------------------------
// Opaque handle
// ---------------------------------------------------------------------------

pub struct PortablePty {
    master: Box<dyn MasterPty + Send>,
    slave: Box<dyn SlavePty + Send>,
    reader: Mutex<Box<dyn Read + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    child: Option<Box<dyn Child + Send + Sync>>,
    child_pid: i32,
    /// Cached exit code — once we detect the child has exited, we store the
    /// result here so that repeated `tryWait` / `wait` calls return the same
    /// value even after the process has been reaped.
    cached_exit_code: Option<c_int>,
}

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

/// Open a new PTY with the given dimensions.
///
/// On success, writes the opaque handle to `*out` and returns `Ok`.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_open(
    rows: u16,
    cols: u16,
    out: *mut *mut PortablePty,
) -> PortablePtyResult {
    if out.is_null() {
        return PortablePtyResult::ErrNull;
    }

    let pty_system = native_pty_system();
    let size = PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    };

    let pair = match pty_system.openpty(size) {
        Ok(pair) => pair,
        Err(_) => return PortablePtyResult::ErrOpen,
    };

    #[cfg(target_os = "android")]
    normalize_android_pty_termios(&pair.master);

    let reader = match pair.master.try_clone_reader() {
        Ok(r) => r,
        Err(_) => {
            return PortablePtyResult::ErrOpen;
        }
    };
    let writer = match pair.master.take_writer() {
        Ok(w) => w,
        Err(_) => {
            return PortablePtyResult::ErrOpen;
        }
    };

    let handle = Box::new(PortablePty {
        master: pair.master,
        slave: pair.slave,
        reader: Mutex::new(reader),
        writer: Mutex::new(writer),
        child: None,
        child_pid: -1,
        cached_exit_code: None,
    });

    unsafe {
        *out = Box::into_raw(handle);
    }
    PortablePtyResult::Ok
}

/// Spawn a child process attached to the PTY.
///
/// - `cmd`: null-terminated executable path.
/// - `argv`: null-terminated array of null-terminated argument strings,
///   or NULL to use `cmd` as the sole argument.
/// - `envp`: null-terminated array of `"KEY=VALUE"` strings, or NULL to
///   inherit the current environment.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_spawn(
    handle: *mut PortablePty,
    cmd: *const c_char,
    argv: *const *const c_char,
    envp: *const *const c_char,
) -> PortablePtyResult {
    let pty = match unsafe { handle.as_mut() } {
        Some(p) => p,
        None => return PortablePtyResult::ErrNull,
    };
    if cmd.is_null() {
        return PortablePtyResult::ErrNull;
    }

    let cmd_str = unsafe { CStr::from_ptr(cmd) };
    let cmd_str = match cmd_str.to_str() {
        Ok(s) => s,
        Err(_) => return PortablePtyResult::ErrSpawn,
    };

    let mut builder = CommandBuilder::new(cmd_str);

    // Parse argv
    if !argv.is_null() {
        let mut args = Vec::new();
        unsafe {
            let mut i = 0;
            loop {
                let arg = *argv.add(i);
                if arg.is_null() {
                    break;
                }
                match CStr::from_ptr(arg).to_str() {
                    Ok(s) => args.push(s.to_owned()),
                    Err(_) => return PortablePtyResult::ErrSpawn,
                }
                i += 1;
            }
        }
        // CommandBuilder::new already sets argv[0], so skip it if present
        if args.len() > 1 {
            builder.args(&args[1..]);
        }
    }

    // Parse envp
    if !envp.is_null() {
        // Clear inherited env and set only what's provided
        builder.env_clear();
        unsafe {
            let mut i = 0;
            loop {
                let entry = *envp.add(i);
                if entry.is_null() {
                    break;
                }
                if let Ok(s) = CStr::from_ptr(entry).to_str() {
                    if let Some((key, val)) = s.split_once('=') {
                        builder.env(key, val);
                    }
                }
                i += 1;
            }
        }
    }

    // Block SIGCHLD around spawn+register so the child can't be reaped
    // before we've registered its PID in the SIGCHLD handler registry.
    #[cfg(unix)]
    let mut old_mask: libc::sigset_t = unsafe { std::mem::zeroed() };
    #[cfg(unix)]
    {
        ensure_sigchld_handler();
        let mut block_set: libc::sigset_t = unsafe { std::mem::zeroed() };
        unsafe {
            libc::sigemptyset(&mut block_set);
            libc::sigaddset(&mut block_set, libc::SIGCHLD);
            libc::sigprocmask(libc::SIG_BLOCK, &block_set, &mut old_mask);
        }
    }

    // Spawn the child on the slave side
    match pty.slave.as_ref().spawn_command(builder) {
        Ok(child) => {
            let pid = child.process_id().map(|p| p as i32).unwrap_or(-1);
            pty.child = Some(child);
            pty.child_pid = pid;
            // Register this PID with the SIGCHLD handler so we capture
            // exit status before the Dart VM's handler reaps the child.
            #[cfg(unix)]
            {
                if pid > 0 {
                    register_pid(pid);
                }
                unsafe {
                    libc::sigprocmask(libc::SIG_SETMASK, &old_mask, std::ptr::null_mut());
                }
            }
            PortablePtyResult::Ok
        }
        Err(_) => {
            // Unblock SIGCHLD on error path too.
            #[cfg(unix)]
            unsafe {
                libc::sigprocmask(libc::SIG_SETMASK, &old_mask, std::ptr::null_mut());
            }
            PortablePtyResult::ErrSpawn
        }
    }
}

/// Read bytes from the PTY master side (child's stdout).
///
/// Returns number of bytes read, or -1 on error/EOF.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_read(handle: *mut PortablePty, buf: *mut u8, len: usize) -> i64 {
    let pty = match unsafe { handle.as_mut() } {
        Some(p) => p,
        None => return -1,
    };
    if buf.is_null() || len == 0 {
        return -1;
    }

    let slice = unsafe { std::slice::from_raw_parts_mut(buf, len) };
    let mut reader = match pty.reader.lock() {
        Ok(r) => r,
        Err(_) => return -1,
    };

    match reader.read(slice) {
        Ok(0) => 0, // EOF
        Ok(n) => n as i64,
        Err(_) => -1,
    }
}

/// Write bytes to the PTY master side (child's stdin).
///
/// Returns number of bytes written, or -1 on error.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_write(handle: *mut PortablePty, buf: *const u8, len: usize) -> i64 {
    let pty = match unsafe { handle.as_mut() } {
        Some(p) => p,
        None => return -1,
    };
    if buf.is_null() || len == 0 {
        return -1;
    }

    let slice = unsafe { std::slice::from_raw_parts(buf, len) };
    let mut writer = match pty.writer.lock() {
        Ok(w) => w,
        Err(_) => return -1,
    };

    match writer.write(slice) {
        Ok(n) => {
            let _ = writer.flush();
            n as i64
        }
        Err(_) => -1,
    }
}

/// Resize the PTY.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_resize(
    handle: *mut PortablePty,
    rows: u16,
    cols: u16,
) -> PortablePtyResult {
    let pty = match unsafe { handle.as_mut() } {
        Some(p) => p,
        None => return PortablePtyResult::ErrNull,
    };

    let size = PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    };

    match pty.master.resize(size) {
        Ok(()) => PortablePtyResult::Ok,
        Err(_) => PortablePtyResult::ErrResize,
    }
}

/// Get the PTY master side file descriptor.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_master_fd(handle: *mut PortablePty) -> c_int {
    let pty = match unsafe { handle.as_ref() } {
        Some(p) => p,
        None => return -1,
    };

    #[cfg(unix)]
    {
        pty.master.as_ref().as_raw_fd().unwrap_or(-1)
    }

    #[cfg(not(unix))]
    {
        -1
    }
}

/// Get the current PTY size as tracked by the kernel.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_get_size(
    handle: *mut PortablePty,
    out_rows: *mut u16,
    out_cols: *mut u16,
    out_pixel_width: *mut u16,
    out_pixel_height: *mut u16,
) -> PortablePtyResult {
    let pty = match unsafe { handle.as_mut() } {
        Some(p) => p,
        None => return PortablePtyResult::ErrNull,
    };

    if out_rows.is_null()
        || out_cols.is_null()
        || out_pixel_width.is_null()
        || out_pixel_height.is_null()
    {
        return PortablePtyResult::ErrNull;
    }

    let size = match pty.master.get_size() {
        Ok(size) => size,
        Err(_) => return PortablePtyResult::ErrSize,
    };

    unsafe {
        *out_rows = size.rows;
        *out_cols = size.cols;
        *out_pixel_width = size.pixel_width;
        *out_pixel_height = size.pixel_height;
    }
    PortablePtyResult::Ok
}

/// Get the child PID, or -1 if no child has been spawned.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_child_pid(handle: *const PortablePty) -> i32 {
    match unsafe { handle.as_ref() } {
        Some(pty) => pty.child_pid,
        None => -1,
    }
}

/// Non-blocking wait for child exit.
///
/// Returns `Ok` if child exited (writes exit code to `*out_status`).
/// Returns `ErrWait` if child is still running.
///
/// Handles the case where the Dart VM (or another runtime) has already reaped
/// the child via its own `SIGCHLD` / `waitpid(-1, …)` handler. When the
/// upstream `try_wait()` fails with `ECHILD`, we fall back to
/// `libc::waitpid(pid, WNOHANG)` and `kill(pid, 0)` to determine the true
/// process state.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_wait(
    handle: *mut PortablePty,
    out_status: *mut c_int,
) -> PortablePtyResult {
    let pty = match unsafe { handle.as_mut() } {
        Some(p) => p,
        None => return PortablePtyResult::ErrNull,
    };

    // Return cached exit code if we already detected exit.
    if let Some(code) = pty.cached_exit_code {
        if !out_status.is_null() {
            unsafe {
                *out_status = code;
            }
        }
        return PortablePtyResult::Ok;
    }

    if pty.child.is_none() {
        return PortablePtyResult::ErrWait;
    }

    // Check the SIGCHLD registry — our handler may have already captured
    // the exit status before the Dart VM's handler could reap the child.
    #[cfg(unix)]
    if pty.child_pid > 0 {
        if let Some(code) = lookup_cached_status(pty.child_pid) {
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }

        // Pre-emptive waitpid: try to reap the child directly before
        // portable-pty's try_wait() which may fail with ECHILD if the
        // Dart VM's SIGCHLD handler already reaped it.
        let mut raw_status: c_int = 0;
        let ret = unsafe { libc::waitpid(pty.child_pid, &mut raw_status, libc::WNOHANG) };
        if ret == pty.child_pid {
            let code = if libc::WIFEXITED(raw_status) {
                libc::WEXITSTATUS(raw_status)
            } else if libc::WIFSIGNALED(raw_status) {
                128 + libc::WTERMSIG(raw_status)
            } else {
                -1
            };
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }
        if ret == -1 {
            // Already reaped by another thread
        }
        // ret == 0: still running, proceed to try_wait
        // ret == -1: already reaped, proceed to try_wait (will get ECHILD)
    }

    // Try the upstream `try_wait()` first — works when the Dart VM hasn't
    // reaped the child yet.
    let child = pty.child.as_mut().unwrap();
    match child.try_wait() {
        Ok(Some(status)) => {
            let code: c_int = status.exit_code().try_into().unwrap_or(-1);
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }
        Ok(None) => {
            // Child is genuinely still running.
            return PortablePtyResult::ErrWait;
        }
        Err(_) => {
            // Likely ECHILD — Dart VM already reaped the child.
            // Fall through to manual detection below.
        }
    }

    // --- Fallback: manual detection for already-reaped children ---
    #[cfg(unix)]
    {
        let pid = pty.child_pid;
        if pid <= 0 {
            return PortablePtyResult::ErrWait;
        }

        // Try waitpid directly — might succeed if there's still a zombie.
        let mut status: c_int = 0;
        let ret = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if ret == pid {
            // We managed to reap it ourselves.
            let code = if libc::WIFEXITED(status) {
                libc::WEXITSTATUS(status)
            } else if libc::WIFSIGNALED(status) {
                // Convention: 128 + signal number
                128 + libc::WTERMSIG(status)
            } else {
                -1
            };
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        } else if ret == 0 {
            // waitpid returned 0 with WNOHANG — child is still running.
            return PortablePtyResult::ErrWait;
        }
        // ret == -1: waitpid failed (ECHILD = already reaped by someone else).
        // Re-check the SIGCHLD registry — our handler may have reaped the
        // child between the initial registry check and now.
        if let Some(code) = lookup_cached_status(pid) {
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }
        // Check if the process still exists.
        let kill_ret = unsafe { libc::kill(pid, 0) };
        if kill_ret == -1 && get_errno() == libc::ESRCH {
            // Process doesn't exist — it exited and was reaped but our
            // handler didn't capture it. Report 0 as fallback.
            let code = 0;
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }
        // Process exists but we can't wait on it (shouldn't happen, but be safe).
        return PortablePtyResult::ErrWait;
    }

    #[cfg(not(unix))]
    {
        // On non-POSIX platforms we have no fallback.
        return PortablePtyResult::ErrWait;
    }
}

/// Block until the child exits and return its exit code.
///
/// Like `portable_pty_wait`, handles the case where the child has already
/// been reaped by the Dart VM's `SIGCHLD` handler.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_wait_blocking(
    handle: *mut PortablePty,
    out_status: *mut c_int,
) -> PortablePtyResult {
    let pty = match unsafe { handle.as_mut() } {
        Some(p) => p,
        None => return PortablePtyResult::ErrNull,
    };

    // Return cached exit code if we already detected exit.
    if let Some(code) = pty.cached_exit_code {
        if !out_status.is_null() {
            unsafe {
                *out_status = code;
            }
        }
        return PortablePtyResult::Ok;
    }

    if pty.child.is_none() {
        return PortablePtyResult::ErrWait;
    }

    // Check the SIGCHLD registry first.
    #[cfg(unix)]
    if pty.child_pid > 0 {
        if let Some(code) = lookup_cached_status(pty.child_pid) {
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }
    }

    // Try the upstream blocking `wait()` first.
    let child = pty.child.as_mut().unwrap();
    match child.wait() {
        Ok(status) => {
            let code: c_int = status.exit_code().try_into().unwrap_or(-1);
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }
        Err(_) => {
            // Likely ECHILD — fall through to manual detection.
        }
    }

    // --- Fallback: manual detection for already-reaped children ---
    #[cfg(unix)]
    {
        let pid = pty.child_pid;
        if pid <= 0 {
            return PortablePtyResult::ErrWaitBlocking;
        }

        // Try waitpid (blocking) — will fail immediately with ECHILD if already reaped.
        let mut status: c_int = 0;
        let ret = unsafe { libc::waitpid(pid, &mut status, 0) };
        if ret == pid {
            let code = if libc::WIFEXITED(status) {
                libc::WEXITSTATUS(status)
            } else if libc::WIFSIGNALED(status) {
                128 + libc::WTERMSIG(status)
            } else {
                -1
            };
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }
        // ret == -1 (ECHILD): already reaped. Re-check registry.
        if let Some(code) = lookup_cached_status(pid) {
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }
        // Check if process is gone.
        let kill_ret = unsafe { libc::kill(pid, 0) };
        if kill_ret == -1 && get_errno() == libc::ESRCH {
            let code = 0;
            pty.cached_exit_code = Some(code);
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            return PortablePtyResult::Ok;
        }
        return PortablePtyResult::ErrWaitBlocking;
    }

    #[cfg(not(unix))]
    {
        return PortablePtyResult::ErrWaitBlocking;
    }
}

/// Kill the child process.
///
/// On POSIX, `signal` is the signal number (e.g. 15 for SIGTERM).
/// On Windows, `signal` is ignored — the process is terminated.
///
/// If the child has already exited (or been reaped), returns `Ok` rather
/// than failing.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_kill(handle: *mut PortablePty, signal: c_int) -> PortablePtyResult {
    let pty = match unsafe { handle.as_mut() } {
        Some(p) => p,
        None => return PortablePtyResult::ErrNull,
    };

    // If we already know the child exited, killing is a no-op.
    if pty.cached_exit_code.is_some() {
        return PortablePtyResult::Ok;
    }

    // Check the SIGCHLD registry — child may have exited already.
    #[cfg(unix)]
    if pty.child_pid > 0 {
        if let Some(code) = lookup_cached_status(pty.child_pid) {
            pty.cached_exit_code = Some(code);
            return PortablePtyResult::Ok;
        }
    }

    if pty.child.is_none() {
        return PortablePtyResult::ErrKill;
    }

    #[cfg(unix)]
    {
        let pid = pty.child_pid;
        if pid <= 0 {
            return PortablePtyResult::ErrKill;
        }

        let ret = unsafe { libc::kill(pid, signal) };
        if ret == 0 {
            return PortablePtyResult::Ok;
        }
        // kill failed — check if the process is already dead (ESRCH).
        if get_errno() == libc::ESRCH {
            // Process already exited — treat as success.
            return PortablePtyResult::Ok;
        }
        return PortablePtyResult::ErrKill;
    }

    #[cfg(not(unix))]
    {
        // On Windows, fall back to the upstream `child.kill()` which calls
        // TerminateProcess.
        let child = pty.child.as_mut().unwrap();
        match child.kill() {
            Ok(()) => PortablePtyResult::Ok,
            Err(_) => PortablePtyResult::ErrKill,
        }
    }
}

/// Return the master process group ID (POSIX) or -1 when unsupported.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_process_group_leader(handle: *const PortablePty) -> c_int {
    let pty = match unsafe { handle.as_ref() } {
        Some(p) => p,
        None => return -1,
    };

    #[cfg(unix)]
    {
        pty.master.process_group_leader().unwrap_or(-1)
    }

    #[cfg(not(unix))]
    {
        -1
    }
}

/// Get the current terminal mode flags.
///
/// - `out_canonical`: true when canonical mode is enabled.
/// - `out_echo`: true when echo mode is enabled.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_get_mode(
    handle: *mut PortablePty,
    out_canonical: *mut bool,
    out_echo: *mut bool,
) -> PortablePtyResult {
    let pty = match unsafe { handle.as_mut() } {
        Some(p) => p,
        None => return PortablePtyResult::ErrNull,
    };
    if out_canonical.is_null() || out_echo.is_null() {
        return PortablePtyResult::ErrNull;
    }

    #[cfg(unix)]
    {
        let fd = match pty.master.as_ref().as_raw_fd() {
            Some(fd) => fd,
            None => return PortablePtyResult::ErrMode,
        };

        let mut termios = std::mem::MaybeUninit::<libc::termios>::uninit();
        if unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) } != 0 {
            return PortablePtyResult::ErrMode;
        }
        let termios = unsafe { termios.assume_init() };
        let flags = termios.c_lflag;

        unsafe {
            *out_canonical = (flags & libc::ICANON) != 0;
            *out_echo = (flags & libc::ECHO) != 0;
        }

        PortablePtyResult::Ok
    }

    #[cfg(not(unix))]
    {
        PortablePtyResult::ErrMode
    }
}

/// Close the PTY and free all resources.
///
/// Kills the child process if still running. Safe to call with NULL.
/// Handles the case where the child was already reaped by the Dart VM.
#[unsafe(no_mangle)]
pub extern "C" fn portable_pty_close(handle: *mut PortablePty) {
    if handle.is_null() {
        return;
    }

    let mut pty = unsafe { Box::from_raw(handle) };

    // Unregister from the SIGCHLD registry before cleanup.
    #[cfg(unix)]
    if pty.child_pid > 0 {
        unregister_pid(pty.child_pid);
    }

    // Kill child if still running
    if let Some(ref mut child) = pty.child {
        // Try to kill — ignore errors (child may already be dead/reaped).
        let _ = child.kill();
        // Try to wait — ignore errors (child may already be reaped).
        let _ = child.wait();

        // If the above failed because the Dart VM reaped the child,
        // there's nothing more to do — the child is gone.
        #[cfg(unix)]
        if pty.child_pid > 0 {
            // Best-effort: try direct waitpid to clean up any remaining zombie.
            let mut status: c_int = 0;
            unsafe {
                libc::waitpid(pty.child_pid, &mut status, libc::WNOHANG);
            }
        }
    }

    // pty is dropped here, closing file descriptors
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr;

    #[test]
    fn test_open_and_close() {
        let mut handle: *mut PortablePty = ptr::null_mut();
        let result = portable_pty_open(24, 80, &mut handle);
        assert!(
            matches!(result, PortablePtyResult::Ok),
            "portable_pty_open returned: {}",
            result as u32,
        );
        assert!(!handle.is_null());
        portable_pty_close(handle);
    }

    #[test]
    fn test_null_handle() {
        let result = portable_pty_open(24, 80, ptr::null_mut());
        assert!(matches!(result, PortablePtyResult::ErrNull));
    }

    #[test]
    fn test_close_null_is_safe() {
        portable_pty_close(ptr::null_mut());
    }

    #[cfg(unix)]
    #[test]
    fn test_spawn_and_read() {
        use std::ffi::CString;

        let mut handle: *mut PortablePty = ptr::null_mut();
        let result = portable_pty_open(24, 80, &mut handle);
        assert!(
            matches!(result, PortablePtyResult::Ok),
            "portable_pty_open returned: {}",
            result as u32,
        );

        let cmd = CString::new("/bin/echo").unwrap();
        let arg0 = CString::new("echo").unwrap();
        let arg1 = CString::new("hello").unwrap();
        let argv: [*const c_char; 3] = [arg0.as_ptr(), arg1.as_ptr(), ptr::null()];

        let result = portable_pty_spawn(handle, cmd.as_ptr(), argv.as_ptr(), ptr::null());
        assert!(
            matches!(result, PortablePtyResult::Ok),
            "portable_pty_spawn returned: {}",
            result as u32,
        );

        // Give the child a moment to produce output
        std::thread::sleep(std::time::Duration::from_millis(200));

        let mut buf = [0u8; 256];
        let n = portable_pty_read(handle, buf.as_mut_ptr(), buf.len());
        assert!(n > 0, "Expected to read some output, got {n}");

        let output = std::str::from_utf8(&buf[..n as usize]).unwrap();
        assert!(
            output.contains("hello"),
            "Expected 'hello' in output: {output}"
        );

        portable_pty_close(handle);
    }
}
