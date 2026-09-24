//! A pseudoterminal and the process on the other end of it.
//!
//! Enough to run a real program under a real PTY, which is what any honest
//! end-to-end test needs: conformance suites like esctest drive the terminal
//! by writing to their own stdout and reading replies from stdin, so there
//! has to be a process whose controlling terminal is the one under test.

use std::collections::HashMap;
use std::ffi::{CString, OsString};
use std::os::unix::ffi::OsStrExt;
use std::fs::File;
use std::os::unix::io::FromRawFd;

pub struct Pty {
    pub master: File,
    pid: libc::pid_t,
}

/// Resolves `program` against `PATH` the way `execvp` would, but returns the
/// full path instead of leaving the search to the child: after `fork`, only
/// async-signal-safe calls are legal, and the libc `PATH` search behind
/// `execvp` is not one of them.
///
/// A name containing a slash is used as-is, matching `execvp`. A bare name
/// that is not found on `PATH` is also returned as-is, so `execve` fails with
/// `ENOENT` and the child exits 127 -- the same outcome `execvp` would give.
fn resolve_program_path(program: &str) -> CString {
    if !program.contains('/')
        && let Ok(path_var) = std::env::var("PATH")
    {
        for dir in path_var.split(':') {
            let dir = if dir.is_empty() { "." } else { dir };
            let candidate = format!("{dir}/{program}");
            if is_executable_file(&candidate) {
                return CString::new(candidate).expect("resolved PATH entry contains a NUL");
            }
        }
    }
    CString::new(program).expect("argv entry contains a NUL")
}

/// Whether `path` is a regular, executable file -- the check `execvp` applies
/// to each `PATH` candidate before trying it.
fn is_executable_file(path: &str) -> bool {
    let Ok(c_path) = CString::new(path) else {
        return false;
    };
    unsafe {
        let mut st: libc::stat = std::mem::zeroed();
        if libc::stat(c_path.as_ptr(), &mut st) != 0 {
            return false;
        }
        if st.st_mode & libc::S_IFMT != libc::S_IFREG {
            return false;
        }
        libc::access(c_path.as_ptr(), libc::X_OK) == 0
    }
}

impl Pty {
    /// Runs `shell` with no arguments. The common case, and what the desktop
    /// demo uses.
    pub fn spawn(shell: &str, rows: u16, cols: u16) -> Self {
        Self::spawn_command(&[shell], &[], rows, cols)
    }

    /// Runs `argv` on a new pseudoterminal sized `cols` x `rows`.
    ///
    /// `env` entries are applied to the child on top of the inherited
    /// environment, after `TERM` has been defaulted -- so a caller that wants
    /// a different `TERM` can simply pass one.
    ///
    /// # Panics
    ///
    /// If the pty cannot be allocated or the process cannot be forked. Both
    /// mean the host is out of a resource the caller cannot do anything
    /// about, and every caller here is a test or a demo.
    pub fn spawn_command(argv: &[&str], env: &[(&str, &str)], rows: u16, cols: u16) -> Self {
        assert!(!argv.is_empty(), "spawn_command needs a program to run");

        // Everything the child needs -- argv, envp and the resolved
        // executable path -- is built before the fork: after it, only
        // async-signal-safe calls are legal in the child, which rules out
        // both `setenv` and the `PATH` search inside `execvp`.
        let args: Vec<CString> = argv
            .iter()
            .map(|a| CString::new(*a).expect("argv entry contains a NUL"))
            .collect();
        let mut arg_ptrs: Vec<*const libc::c_char> =
            args.iter().map(|a| a.as_ptr()).collect();
        arg_ptrs.push(std::ptr::null());

        let exec_path = resolve_program_path(argv[0]);

        // The child's environment is the inherited environment with `TERM`
        // defaulted and then the caller's pairs applied on top, so a caller
        // that wants a different `TERM` can simply pass one.
        // vars_os, not vars: an inherited variable that is not UTF-8 must be
        // passed through, not panic the spawn.
        let mut env_map: HashMap<OsString, OsString> = std::env::vars_os().collect();
        env_map.insert("TERM".into(), "xterm-256color".into());
        for (k, v) in env {
            assert!(!k.contains('\0'), "env key contains a NUL");
            assert!(!v.contains('\0'), "env value contains a NUL");
            env_map.insert((*k).into(), (*v).into());
        }
        let env_cstrings: Vec<CString> = env_map
            .iter()
            .map(|(k, v)| {
                let mut entry = k.as_bytes().to_vec();
                entry.push(b'=');
                entry.extend_from_slice(v.as_bytes());
                CString::new(entry).expect("env entry contains a NUL")
            })
            .collect();
        let mut env_ptrs: Vec<*const libc::c_char> =
            env_cstrings.iter().map(|e| e.as_ptr()).collect();
        env_ptrs.push(std::ptr::null());

        unsafe {
            let mut master_fd: libc::c_int = 0;
            let mut slave_fd: libc::c_int = 0;

            let mut win = libc::winsize {
                ws_row: rows,
                ws_col: cols,
                ws_xpixel: 0,
                ws_ypixel: 0,
            };

            if libc::openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                // `*mut` on Apple's libc, `*const` on Linux: a raw pointer
                // from a mutable place fits both.
                std::ptr::addr_of_mut!(win),
            ) < 0
            {
                panic!("openpty failed");
            }

            let pid = libc::fork();
            if pid < 0 {
                panic!("fork failed");
            } else if pid == 0 {
                libc::close(master_fd);
                libc::setsid();

                // Default signal handling and nothing blocked: a disposition
                // the host ignores (SIGHUP under nohup, SIGINT from some
                // launchers) would otherwise pass through exec to the
                // program and everything it starts. All async-signal-safe.
                let mut empty: libc::sigset_t = std::mem::zeroed();
                libc::sigemptyset(&mut empty);
                libc::sigprocmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
                for signal in 1..32 {
                    libc::signal(signal, libc::SIG_DFL);
                }

                libc::ioctl(slave_fd, libc::TIOCSCTTY as libc::c_ulong, 0);

                libc::dup2(slave_fd, libc::STDIN_FILENO);
                libc::dup2(slave_fd, libc::STDOUT_FILENO);
                libc::dup2(slave_fd, libc::STDERR_FILENO);

                if slave_fd > libc::STDERR_FILENO {
                    libc::close(slave_fd);
                }

                libc::execve(exec_path.as_ptr(), arg_ptrs.as_ptr(), env_ptrs.as_ptr());
                // Only reachable if exec failed; the parent sees the status.
                libc::_exit(127);
            } else {
                libc::close(slave_fd);
                Pty {
                    master: File::from_raw_fd(master_fd),
                    pid,
                }
            }
        }
    }

    /// The child's process id.
    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// Blocks until the child exits and returns its exit code, or `128 +
    /// signal` if it was killed -- the convention a shell reports.
    pub fn wait(&self) -> i32 {
        let mut status: libc::c_int = 0;
        unsafe {
            if libc::waitpid(self.pid, &mut status, 0) < 0 {
                return -1;
            }
        }
        if libc::WIFEXITED(status) {
            libc::WEXITSTATUS(status)
        } else if libc::WIFSIGNALED(status) {
            128 + libc::WTERMSIG(status)
        } else {
            -1
        }
    }

    /// Asks the child to stop, for a caller that has run out of patience.
    pub fn terminate(&self) {
        unsafe {
            libc::kill(self.pid, libc::SIGTERM);
        }
    }

    /// Tells the child the terminal changed size.
    pub fn resize(&self, rows: u16, cols: u16) {
        let win = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe {
            use std::os::unix::io::AsRawFd;
            libc::ioctl(self.master.as_raw_fd(), libc::TIOCSWINSZ, &win);
        }
    }
}
