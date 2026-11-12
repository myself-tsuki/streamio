//
//  SystemMonitor.swift
//  Streamio
//
//  Samples the figures OBS shows in its status bar: process CPU, GPU utilisation and memory.
//

import Darwin
import Foundation
import IOKit

nonisolated struct SystemUsage: Equatable, Sendable {
    /// Streamio's share of total CPU capacity, 0…100.
    var cpuPercent: Double
    /// Whole-GPU utilisation reported by the driver, 0…100, if available.
    var gpuPercent: Double?
    /// Physical memory footprint in bytes (what Activity Monitor shows).
    var memoryBytes: UInt64
}

nonisolated final class SystemMonitor {
    private var lastCPUTime: Double?
    private var lastWallTime: Double?
    private let processorCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    func sample() -> SystemUsage {
        SystemUsage(cpuPercent: processCPUPercent(), gpuPercent: Self.gpuUtilization(), memoryBytes: Self.memoryFootprint())
    }

    private func processCPUPercent() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let cpu = Self.seconds(usage.ru_utime) + Self.seconds(usage.ru_stime)
        let wall = ProcessInfo.processInfo.systemUptime
        defer {
            lastCPUTime = cpu
            lastWallTime = wall
        }
        guard let lastCPUTime, let lastWallTime, wall > lastWallTime else { return 0 }
        return min(100, max(0, (cpu - lastCPUTime) / (wall - lastWallTime) / processorCount * 100))
    }

    private static func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }

    /// Reads `PerformanceStatistics` from every IOAccelerator (Apple silicon, AMD and Intel GPUs).
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var highest: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let property = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
               let statistics = property.takeRetainedValue() as? [String: Any] {
                let value = (statistics["Device Utilization %"] ?? statistics["GPU Activity(%)"]) as? NSNumber
                if let value {
                    highest = max(highest ?? 0, value.doubleValue)
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return highest
    }

    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Free space on the volume holding `url`, for the recording-space readout.
    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
