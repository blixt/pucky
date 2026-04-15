#if !targetEnvironment(simulator)
import Darwin
import Foundation
import MLX
import os.log

/// Reports the app's true memory footprint and the MLX buffer pool
/// state to the system log under the `[mem]` tag, so an external
/// `idevicesyslog` watcher can stream the numbers in real time.
///
/// We log:
///   - **rss**:    physical memory the kernel attributes to this app
///                 (`mach_task_basic_info.resident_size`). This is the
///                 number jetsam compares against the foreground limit.
///   - **vsize**:  virtual size (rarely interesting on iOS but cheap).
///   - **active**: bytes held by live `MLXArray`s (`MLX.Memory.activeMemory`).
///   - **cache**:  bytes in MLX's recyclable buffer pool
///                 (`MLX.Memory.cacheMemory`). Capped via
///                 `MLX.GPU.set(cacheLimit:)`.
///   - **peak**:   peak `active` since process start.
///
/// Numbers are reported in MB (rounded down) so the lines stay grep-friendly.
enum MemoryProbe {
    private static let log = Logger(subsystem: "dev.pucky.app", category: "mem")

    static func snapshot(_ label: String) {
        let rss = Self.taskRSS() / (1024 * 1024)
        let vsize = Self.taskVirtualSize() / (1024 * 1024)
        let active = MLX.Memory.activeMemory / (1024 * 1024)
        let cache = MLX.Memory.cacheMemory / (1024 * 1024)
        let peak = MLX.Memory.peakMemory / (1024 * 1024)
        log.notice(
            "[mem] \(label, privacy: .public) rss=\(rss)MB vsize=\(vsize)MB active=\(active)MB cache=\(cache)MB peak=\(peak)MB"
        )
    }

    /// Resident set size from `mach_task_basic_info`. This is the
    /// number iOS uses for jetsam decisions on the foreground app.
    private static func taskRSS() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return kerr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private static func taskVirtualSize() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return kerr == KERN_SUCCESS ? Int(info.virtual_size) : 0
    }
}
#endif
