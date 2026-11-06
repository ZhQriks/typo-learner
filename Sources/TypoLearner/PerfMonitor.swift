import Darwin
import Foundation

/// The app's own CPU and memory use, so you can see it stays out of the way.
struct PerfMonitor {
    struct Reading: Equatable {
        var cpuPercent = 0.0
        var memoryMB = 0.0
        var microsPerKey: Double?
    }

    private var lastCPU = PerfMonitor.cpuSeconds()
    private var lastWall = Date()

    mutating func read(timing: Core.Timing) -> Reading {
        let cpu = Self.cpuSeconds(), wall = Date()
        let elapsed = wall.timeIntervalSince(lastWall)
        defer { lastCPU = cpu; lastWall = wall }
        return Reading(
            cpuPercent: elapsed > 0 ? (cpu - lastCPU) / elapsed * 100 : 0,
            memoryMB: Self.footprintMB(),
            microsPerKey: timing.keys > 0 ? Double(timing.nanos) / Double(timing.keys) / 1000 : nil
        )
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
