import Foundation
import Darwin
import IOKit
import notify

// Raw machine readings for the Machine Tile. Everything here is a direct system
// call (sysctl, mach, notify, IOKit). Nothing shells out, so one poll costs a few
// hundred microseconds instead of a `top` + `ps` + `sysctl` process per tick.

enum Sysctl {
    static func int32(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static func uint64(_ name: String) -> UInt64? {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    /// Seconds since this Mac booted, sleep included.
    static func uptimeSeconds() -> Double? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }
}

// MARK: - CPU

struct CPUReading {
    var busyPercent: Double   // 0...100 across every core
    var coresWorth: Double    // sum of per-core busy fractions, e.g. 4.2 means "4.2 cores' worth of work"
    var coresHot: Int         // cores more than half busy during the window
    var coreCount: Int
}

/// Needs two reads to produce a number: it reports the busy share between them.
final class CPUReader {
    private var previous: [[UInt32]]?

    func read() -> CPUReading? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        for core in 0..<Int(cpuCount) {
            let base = core * states
            current.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }
        defer { previous = current }
        guard let previous, previous.count == current.count else { return nil }

        var busySum = 0.0, totalSum = 0.0, worth = 0.0
        var hot = 0
        for core in 0..<current.count {
            // Wrapping subtraction: the tick counters are 32-bit and do roll over.
            let user = Double(current[core][0] &- previous[core][0])
            let system = Double(current[core][1] &- previous[core][1])
            let idle = Double(current[core][2] &- previous[core][2])
            let nice = Double(current[core][3] &- previous[core][3])
            let total = user + system + idle + nice
            guard total > 0 else { continue }
            let busy = user + system + nice
            busySum += busy
            totalSum += total
            let fraction = busy / total
            worth += fraction
            if fraction > 0.5 { hot += 1 }
        }
        guard totalSum > 0 else { return nil }
        return CPUReading(busyPercent: busySum / totalSum * 100, coresWorth: worth,
                          coresHot: hot, coreCount: current.count)
    }
}

// MARK: - Memory

struct MemoryReading {
    var totalBytes: UInt64
    var usedBytes: UInt64        // app memory + wired + compressed, the same sum Activity Monitor shows
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var freePercent: Int         // the kernel's own "memory free percentage" (what `memory_pressure -Q` prints)
    var pressureLevel: Int       // 1 normal, 2 warning, 4 critical
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64

    var swapFraction: Double {
        swapTotalBytes == 0 ? 0 : Double(swapUsedBytes) / Double(swapTotalBytes)
    }
}

enum MemoryReader {
    static func read() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS, let total = Sysctl.uint64("hw.memsize") else { return nil }

        let page = UInt64(getpagesize())
        let appPages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let used = appPages * page + wired + compressed

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let haveSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        return MemoryReading(
            totalBytes: total, usedBytes: used, wiredBytes: wired, compressedBytes: compressed,
            freePercent: Sysctl.int32("kern.memorystatus_level") ?? 0,
            pressureLevel: Sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1,
            swapUsedBytes: haveSwap ? swap.xsu_used : 0,
            swapTotalBytes: haveSwap ? swap.xsu_total : 0)
    }
}

// MARK: - Thermal state

enum ThermalReader {
    private static var token: Int32 = 0
    private static var registered = false

    /// 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping. The same number
    /// `notifyutil -g com.apple.system.thermalpressurelevel` prints.
    static func level() -> Int? {
        if !registered {
            guard notify_register_check("com.apple.system.thermalpressurelevel", &token) == NOTIFY_STATUS_OK else {
                return nil
            }
            registered = true
        }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == NOTIFY_STATUS_OK else { return nil }
        return Int(state)
    }
}

// MARK: - SMC (real degrees and fan speed, no sudo)

struct SMCReading {
    var chipCelsius: Double?     // hottest CPU or GPU sensor
    var chipSensorCount: Int
    var fans: [Fan]

    struct Fan {
        var rpm: Double
        var minRPM: Double
        var maxRPM: Double
        /// 0 at the lowest speed the fan ever idles at, 1 flat out.
        var fraction: Double { maxRPM > minRPM ? max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM))) : 0 }
    }
}

/// Talks to the AppleSMC service the way Activity Monitor style tools do. It opens
/// as a normal user. If anything in here fails the tile says "degrees unavailable":
/// it never fills the gap with a made-up number.
final class SMC {
    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct PLim { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        // Explicit padding: C pads this to 12 bytes and Swift would pack the next field
        // right after the 9th, which shifts every later offset and makes every read fail.
        struct KInfo { var size: UInt32 = 0, type: UInt32 = 0, attr: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0, p3: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLim()
        var keyInfo = KInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0
    private(set) var tempKeys: [UInt32] = []
    private(set) var tempKeyNames: [String] = []
    private var fanCount = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        guard MemoryLayout<KeyData>.size == 80 else { return nil }

        // Done once: walk the key table and remember which keys are CPU and GPU
        // temperatures. Per-poll reads then touch only those.
        let total = readUInt32("#KEY") ?? 0
        for index in 0..<Int(total) {
            var input = KeyData()
            input.data8 = 8
            input.data32 = UInt32(index)
            guard call(&input) else { continue }
            let name = Self.name(input.key)
            // Tp = CPU cores, Tg = GPU, by the convention every Apple Silicon reader uses.
            // Apple does not document these names, so the report says they are inferred.
            if name.hasPrefix("Tp") || name.hasPrefix("Tg") {
                if readFloat(input.key) != nil {
                    tempKeys.append(input.key)
                    tempKeyNames.append(name)
                }
            }
        }
        fanCount = Int(readUInt8("FNum") ?? 0)
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read() -> SMCReading {
        var hottest: Double?
        var used = 0
        for key in tempKeys {
            guard let value = readFloat(key) else { continue }
            let degrees = Double(value)
            // A sensor reading 0 or something absurd is a dead sensor, not a cold chip.
            guard degrees > 5, degrees < 125 else { continue }
            used += 1
            hottest = max(hottest ?? degrees, degrees)
        }
        var fans: [SMCReading.Fan] = []
        for index in 0..<fanCount {
            guard let rpm = readFloat(Self.key("F\(index)Ac")),
                  let low = readFloat(Self.key("F\(index)Mn")),
                  let high = readFloat(Self.key("F\(index)Mx")) else { continue }
            fans.append(.init(rpm: Double(rpm), minRPM: Double(low), maxRPM: Double(high)))
        }
        return SMCReading(chipCelsius: hottest, chipSensorCount: used, fans: fans)
    }

    // MARK: low level

    private static func key(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    private static func name(_ key: UInt32) -> String {
        let chars = [UInt8(key >> 24 & 255), UInt8(key >> 16 & 255), UInt8(key >> 8 & 255), UInt8(key & 255)]
        return String(bytes: chars, encoding: .ascii) ?? ""
    }

    private func call(_ input: inout KeyData) -> Bool {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.size
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.size, &output, &size)
        input = output
        return status == KERN_SUCCESS && output.result == 0
    }

    private func readBytes(_ key: UInt32, size: UInt32) -> [UInt8]? {
        var input = KeyData()
        input.key = key
        input.keyInfo.size = size
        input.data8 = 5
        guard call(&input) else { return nil }
        var raw = input.bytes
        return withUnsafeBytes(of: &raw) { Array($0.prefix(Int(size))) }
    }

    private func readFloat(_ key: UInt32) -> Float? {
        guard let b = readBytes(key, size: 4) else { return nil }
        let value = b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        return value.isFinite ? value : nil
    }

    private func readFloat(_ name: String) -> Float? { readFloat(Self.key(name)) }

    private func readUInt32(_ name: String) -> UInt32? {
        guard let b = readBytes(Self.key(name), size: 4) else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func readUInt8(_ name: String) -> UInt8? { readBytes(Self.key(name), size: 1)?.first }
}

// MARK: - Claude processes

struct AppUse {
    var name: String
    var bytes: UInt64
}

struct ClaudeProcesses {
    var count: Int
    var totalFootprintBytes: UInt64
    /// Footprint of every claude process, keyed by pid, so lanes can be matched to a real size.
    var footprintByPid: [Int32: UInt64]
    /// The apps using the most memory, biggest first, so "close some apps" can name them.
    var topApps: [AppUse] = []
}

enum ProcessScanner {
    static let virtualMachine = "Virtual machine"

    /// A virtual machine runs as a macOS system process, so it never shows under the app
    /// that started it. With Docker open, that memory is Docker's.
    static func foldVirtualMachine(_ apps: [String: UInt64]) -> [String: UInt64] {
        var apps = apps
        if apps["Docker"] != nil, let vm = apps.removeValue(forKey: virtualMachine) {
            apps["Docker", default: 0] += vm
        }
        return apps
    }

    /// The name you would close it by, or nil for anything that is not yours to close.
    /// A helper counts toward its app, so Chrome's renderers add up to one Chrome.
    static func appName(path: String) -> String? {
        if isClaudeCode(path) { return "Claude Code" }
        if path.hasSuffix("/node") { return "Node tools" }
        if path.hasSuffix("com.apple.Virtualization.VirtualMachine") { return virtualMachine }
        guard !path.hasPrefix("/System/"), let end = path.range(of: ".app/") else { return nil }
        return (String(path[..<end.lowerBound]) as NSString).lastPathComponent
    }

    // Lowercase /claude is the CLI install. The desktop app lives at /Applications/Claude.app.
    private static func isClaudeCode(_ path: String) -> Bool {
        path.hasSuffix("/claude") || path.contains("/.local/share/claude/")
    }

    /// Finds every Claude Code process (the CLI binary, its versioned copies and its
    /// helpers) by executable path, reads each one's memory footprint, and totals every app.
    static func scanClaude() -> ClaudeProcesses {
        var pids = [Int32](repeating: 0, count: 4096)
        // Returns how many pids it wrote, not bytes, unlike proc_listpids.
        let n = max(0, Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))))
        var footprints: [Int32: UInt64] = [:]
        var apps: [String: UInt64] = [:]
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(n) where pid > 0 {
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            let path = String(cString: pathBuffer)
            guard let app = appName(path: path) else { continue }
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { continue }
            apps[app, default: 0] += usage.ri_phys_footprint
            if isClaudeCode(path) { footprints[pid] = usage.ri_phys_footprint }
        }
        return ClaudeProcesses(count: footprints.count,
                               totalFootprintBytes: footprints.values.reduce(0, +),
                               footprintByPid: footprints,
                               topApps: foldVirtualMachine(apps).map { AppUse(name: $0.key, bytes: $0.value) }
                                   .sorted { $0.bytes > $1.bytes }.prefix(4).map { $0 })
    }
}
