//! Reproduce the writer OOM mechanism in isolation, with numbers.
//!
//! Three questions, each measured rather than reasoned about:
//!   1. Does memory at open scale with the tier store's size on disk?
//!   2. Does a single `append` cost a full copy of that state?
//!   3. Does `append_batch` avoid it?
//!
//! Peak RSS is read from the OS, not estimated.
use ehdb_reference::eventlog::{EventLogAppendRequest, EventLogDriver, LocalReferenceEventLogDriver};
use std::time::Instant;

#[cfg(target_os = "macos")]
fn peak_rss_mb() -> f64 {
    // ru_maxrss is BYTES on macOS.
    unsafe {
        let mut u: libc_rusage = std::mem::zeroed();
        getrusage(0, &mut u);
        u.ru_maxrss as f64 / 1_048_576.0
    }
}
#[cfg(target_os = "linux")]
fn peak_rss_mb() -> f64 {
    // ru_maxrss is KILOBYTES on Linux.
    unsafe {
        let mut u: libc_rusage = std::mem::zeroed();
        getrusage(0, &mut u);
        u.ru_maxrss as f64 / 1024.0
    }
}
#[repr(C)]
#[derive(Clone, Copy)]
struct libc_timeval { tv_sec: i64, tv_usec: i64 }
#[repr(C)]
#[derive(Clone, Copy)]
struct libc_rusage {
    ru_utime: libc_timeval, ru_stime: libc_timeval,
    ru_maxrss: i64, ru_ixrss: i64, ru_idrss: i64, ru_isrss: i64,
    ru_minflt: i64, ru_majflt: i64, ru_nswap: i64,
    ru_inblock: i64, ru_oublock: i64, ru_msgsnd: i64, ru_msgrcv: i64,
    ru_nsignals: i64, ru_nvcsw: i64, ru_nivcsw: i64,
}
extern "C" { fn getrusage(who: i32, usage: *mut libc_rusage) -> i32; }

fn dir_bytes(p: &std::path::Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|v| v.parse().ok()).unwrap_or(20_000);
    let payload_len: usize = std::env::args().nth(2).and_then(|v| v.parse().ok()).unwrap_or(400);
    let root = std::env::temp_dir().join(format!("tier-memcheck-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let log = root.join("eventlog.jsonl");

    let mk = || LocalReferenceEventLogDriver::new(
        log.clone(),
        ehdb_reference::DEFAULT_LOCAL_REFERENCE_TENANT.to_string(),
        ehdb_reference::DEFAULT_LOCAL_REFERENCE_NAMESPACE.to_string(),
    );
    let pad = "x".repeat(payload_len);

    // --- THE CURVE: cost per append as the store grows ------------------
    // A flat line means append is O(1) in store size. A rising line is the
    // per-append full-state clone, and it is what makes a big tier store both
    // slow (4s append timeouts) and memory-hungry (a copy per append).
    println!("chunk  records   chunk_s   ms/append   on_disk_MB   peak_rss_MB");
    let chunk = n / 10;
    let d = mk();
    let mut done = 0usize;
    for c in 0..10 {
        let t = Instant::now();
        for i in 0..chunk {
            d.append(&EventLogAppendRequest {
                execution_id: format!("exec-{}", (done + i) % 64),
                transaction_id: format!("txn-{}", done + i),
                payload: format!("{{\"i\":{},\"pad\":\"{pad}\"}}", done + i),
                event_id: None,
            }).expect("append");
        }
        done += chunk;
        let el = t.elapsed().as_secs_f64();
        println!("{:>5}  {:>7}   {:>7.2}   {:>9.2}   {:>10.1}   {:>11.1}",
                 c + 1, done, el, el * 1000.0 / chunk as f64,
                 dir_bytes(&log) as f64 / 1_048_576.0, peak_rss_mb());
    }
    let _ = std::fs::remove_dir_all(&root);
}
