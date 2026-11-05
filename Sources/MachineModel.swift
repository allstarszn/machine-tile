import Foundation
import SwiftUI

// One shared poll for the whole Machine Tile. A single timer on a background queue
// reads everything, builds one snapshot, and hands it to the view. The view never
// samples anything itself, and nothing runs while the panel is closed.

enum Tone { case ok, warn, bad, neutral }

// MARK: - Claude lanes

struct Lane: Identifiable {
    enum State { case working, waiting, idle, done }
    var id: String
    var name: String
    var state: State
    var isBackground: Bool
    var startedAt: Date?
    var pid: Int32?
}

struct ClaudeReading {
    var lanes: [Lane]
    var processes: ClaudeProcesses
    /// Estimated API-list-price spend for today, from a local cost log if one exists.
    var spendToday: Double?
    var lanesError: String?
    var lanesLoaded: Bool

    var working: [Lane] { lanes.filter { $0.state == .working } }
    var waiting: [Lane] { lanes.filter { $0.state == .waiting }.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) } }
    var idle: [Lane] { lanes.filter { $0.state == .idle } }
}

enum LaneReader {
    private static let claudePath = NSHomeDirectory() + "/.local/bin/claude"

    /// `claude agents --json`: background lanes carry `state` (working, blocked, done),
    /// interactive sessions carry `status` (busy, idle).
    static func read() -> (lanes: [Lane], error: String?) {
        guard FileManager.default.isExecutableFile(atPath: claudePath) else {
            return ([], "claude not found at ~/.local/bin/claude")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: claudePath)
        task.arguments = ["agents", "--json"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return ([], "could not run claude agents") }

        // Guard against a hung call: kill it after 8 seconds rather than stall the poll.
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()

        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ([], "claude agents gave no JSON")
        }
        let lanes: [Lane] = raw.compactMap { item in
            // `claude agents` keeps records of dead sessions. No live process means nothing is
            // running or waiting, so it does not count.
            guard let rawPid = item["pid"] as? Int, kill(Int32(rawPid), 0) == 0 else { return nil }
            let kind = item["kind"] as? String ?? ""
            let background = kind == "background"
            let state: Lane.State
            if background {
                // Only a set `waitingFor` means it needs you. A plain "blocked" does not.
                if let waiting = item["waitingFor"] as? String, !waiting.isEmpty {
                    state = .waiting
                } else {
                    switch item["state"] as? String ?? "" {
                    case "working": state = .working
                    case "blocked": state = (item["status"] as? String) == "busy" ? .working : .idle
                    case "done": state = .done
                    default: state = .idle
                    }
                }
            } else {
                state = (item["status"] as? String) == "busy" ? .working : .idle
            }
            let started = (item["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let id = item["sessionId"] as? String ?? item["id"] as? String ?? UUID().uuidString
            return Lane(id: id, name: item["name"] as? String ?? "unnamed", state: state,
                        isBackground: background, startedAt: started,
                        pid: (item["pid"] as? Int).map { Int32($0) })
        }
        return (lanes, nil)
    }
}

enum SpendReader {
    private static let path = NSHomeDirectory() + "/.claude/metrics/costs.jsonl"

    /// Every row is a running total for its session, so only the newest row per session counts, and "today" is the local day of
    /// that newest row. Reads the file from the end and stops once it is past midnight.
    static func today() -> Double? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var window: UInt64 = 1 << 20
        while true {
            let start = size > window ? size - window : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if start > 0, !lines.isEmpty { lines.removeFirst() }   // first line is cut off mid-row

            var newest: [String: (Date, Double)] = [:]
            var earliest = Date.distantFuture
            for line in lines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let session = obj["session_id"] as? String,
                      let stamp = obj["timestamp"] as? String,
                      let date = isoFractional.date(from: stamp) ?? isoPlain.date(from: stamp) else { continue }
                earliest = min(earliest, date)
                let cost = (obj["estimated_cost_usd"] as? Double) ?? 0
                if let old = newest[session], old.0 > date { continue }
                newest[session] = (date, cost)
            }
            // Done once the window reaches back before midnight, or covers the whole file.
            if start == 0 || earliest < startOfDay {
                return newest.values.filter { $0.0 >= startOfDay }.reduce(0) { $0 + $1.1 }
            }
            window *= 2
        }
    }
}

// MARK: - Snapshot and verdict

struct Room {
    var n: Int
    var tone: Tone
    var label: String          // OK, Slow down, Stop
    var limiter: String        // plain-words reason for the number
    var perLaneBytes: UInt64
    var perLaneMeasured: Bool
    var memorySlots: Int
    var cpuSlots: Int
    var notes: [String]
}

struct Heat {
    var thermalLevel: Int?
    var chipCelsius: Double?
    var fans: [SMCReading.Fan]
    var word: String
    var tone: Tone
    var detail: String
    var short: String          // one word for the glance row
    var fanWord: String        // idle, spinning or loud, no rpm
}

/// The one thing to do right now. Level 0 add more, 1 hold, 2 cut back.
struct Advice {
    var level: Int
    var tone: Tone
    var title: String
    var why: String
}

/// A word and how much it matters, for one row of the glance view.
struct Status {
    var word: String
    var tone: Tone
}

/// One row of the glance view: a word, a bar, and the number the bar is drawing.
struct Meter {
    var label: String
    var word: String
    var tone: Tone
    var fraction: Double?      // nil draws no bar: never a bar from a number that was not read
    var number: String
}

struct RestartAdvice {
    var needed: Bool
    var word: String
    var tone: Tone
    var number: String         // "6.1 of 8 GB swap"
    var fraction: Double       // how close to the line where a restart is worth it
    var note: String?          // the sentence under it, when a restart is worth doing
}

struct MachineSnapshot {
    var date: Date
    var cpu: CPUReading?
    var memory: MemoryReading?
    var heat: Heat
    var claude: ClaudeReading
    var room: Room
    var advice: Advice
    var restart: RestartAdvice
    var uptimeSeconds: Double?
}

enum Verdict {
    /// Memory a lane is assumed to need when none can be measured.
    static let fallbackLaneBytes: UInt64 = 450 << 20
    /// Free memory the machine should keep in reserve before pressure turns bad.
    /// macOS does not publish its pressure thresholds, so this is a stated choice.
    static let reservePercent = 20
    /// Cores one more working lane is assumed to occupy.
    static let coresPerLane = 1.0
    /// Swap is judged in GB, not percent: macOS resizes the swap file itself, so "89% full"
    /// can be 6 GB on a calm Mac. Both lines are stated choices, sized for a 24 GB Mac.
    static let swapTightBytes: UInt64 = 8 << 30
    static let swapFullBytes: UInt64 = 14 << 30
    /// Below this the kernel's free figure counts as tight. The reserve above is the hard floor.
    static let tightFreePercent = 30
    /// A Mac this long since boot is worth restarting at the next quiet moment. A stated choice.
    static let restartDays = 7.0
    /// How long a warning stays up after the reason clears, so a 2-second spike does not
    /// flip the answer back and forth while you are glancing at it.
    static let calmSeconds = 30.0
    /// The top of the heat bar. Apple does not publish a limit, so this is a stated choice:
    /// Apple Silicon chips are generally reported to slow themselves down at about this point.
    static let maxChipCelsius = 105.0

    private static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824.0)
    }

    static func memoryStatus(_ m: MemoryReading) -> Status {
        // Pressure 2 is macOS's warning level and 4 its critical level.
        if m.pressureLevel >= 4 || m.swapUsedBytes >= swapFullBytes { return Status(word: "Full", tone: .bad) }
        if m.pressureLevel >= 2 || m.swapUsedBytes >= swapTightBytes || m.freePercent < tightFreePercent {
            return Status(word: "Tight", tone: .warn)
        }
        return Status(word: "Fine", tone: .ok)
    }

    static func workload(_ c: CPUReading) -> Status {
        if c.busyPercent > 85 { return Status(word: "Maxed", tone: .bad) }
        if c.busyPercent > 60 { return Status(word: "Busy", tone: .warn) }
        return Status(word: "Light", tone: .ok)
    }

    static func advice(cpu: CPUReading?, memory: MemoryReading?, heat: Heat, room: Room,
                       apps: [AppUse]) -> Advice {
        guard let c = cpu, let m = memory else {
            return Advice(level: 0, tone: .neutral, title: "Checking", why: "Reading the machine.")
        }
        // Node tools are servers, not something you quit from the Dock, so they stay in Details.
        let biggest = apps.filter { $0.name != "Node tools" }.prefix(2).map { "\($0.name) \(gb($0.bytes)) GB" }.joined(separator: ", ")
        let close = biggest.isEmpty ? "" : " Biggest: \(biggest)."
        let hold = "Keep what's running."
        if let level = heat.thermalLevel, level >= 2 {
            return Advice(level: 2, tone: .bad, title: "Let it cool down",
                          why: "The Mac is slowing itself down to stay cool. Close something heavy.")
        }
        switch memoryStatus(m).word {
        case "Full":
            return Advice(level: 2, tone: .bad, title: "Close some apps", why: "Memory is full.\(close)")
        case "Tight":
            return Advice(level: 1, tone: .warn, title: "Hold here",
                          why: "\(hold) Memory is tight, so close an app before adding.\(close)")
        default: break
        }
        if heat.tone == .warn {
            return Advice(level: 1, tone: .warn, title: "Hold here", why: "\(hold) It's hot, so add nothing new.")
        }
        if workload(c).tone == .bad {
            return Advice(level: 1, tone: .warn, title: "Hold here", why: "\(hold) The CPU is nearly full.")
        }
        if room.n <= 3 {
            let left = room.n == 0 ? "No room for more" : "Room for \(room.n) more at most"
            return Advice(level: 1, tone: .warn, title: "Hold here", why: "\(hold) \(left).")
        }
        return Advice(level: 0, tone: .ok, title: "Good to add more", why: "Room for about \(room.n) more Claude lanes.")
    }

    static func restart(memory: MemoryReading?, uptimeSeconds: Double?, working: Int) -> RestartAdvice {
        let days = (uptimeSeconds ?? 0) / 86400
        let swap = memory?.swapUsedBytes ?? 0
        // The bar follows whichever reason is closer to its line.
        let swapShare = Double(swap) / Double(swapTightBytes)
        let dayShare = days / restartDays
        let number = swapShare >= dayShare ? "\(gb(swap)) of \(swapTightBytes >> 30) GB swap"
            : "\(Int(days)) of \(Int(restartDays)) days up"
        let fraction = min(1, max(swapShare, dayShare))
        guard swap >= swapTightBytes || days >= restartDays else {
            return RestartAdvice(needed: false, word: "Not needed", tone: .ok, number: number, fraction: fraction, note: nil)
        }
        if working == 0 {
            return RestartAdvice(needed: true, word: "Good time", tone: .warn, number: number, fraction: fraction,
                                 note: "Nothing is working, so a restart costs you nothing.")
        }
        let lanes = working == 1 ? "your working lane finishes" : "your \(working) working lanes finish"
        return RestartAdvice(needed: true, word: "Soon", tone: .warn, number: number, fraction: fraction,
                             note: "Restart after \(lanes).")
    }

    // MARK: the bars

    static func heatMeter(_ h: Heat) -> Meter {
        Meter(label: "Heat", word: h.tone == .bad ? h.short : "\(h.short), \(h.fanWord)", tone: h.tone,
              fraction: h.chipCelsius.map { $0 / maxChipCelsius },
              number: h.chipCelsius.map { "\(Int($0.rounded())) of \(Int(maxChipCelsius)) C" } ?? "degrees unavailable")
    }

    static func workloadMeter(_ c: CPUReading) -> Meter {
        let s = workload(c)
        return Meter(label: "Workload", word: s.word, tone: s.tone, fraction: c.busyPercent / 100,
                     number: "\(Int(c.busyPercent.rounded())) of 100%")
    }

    static func memoryMeter(_ m: MemoryReading) -> Meter {
        let s = memoryStatus(m)
        return Meter(label: "Memory", word: s.word, tone: s.tone, fraction: Double(m.usedBytes) / Double(m.totalBytes),
                     number: "\(gb(m.usedBytes)) of \(gb(m.totalBytes)) GB")
    }

    /// The whole bar is what is working now plus the room left, so it fills as lanes start.
    static func claudeMeter(_ c: ClaudeReading, room: Room) -> Meter {
        let working = c.working.count
        let limit = working + room.n
        return Meter(label: "Claude", word: working == 0 ? "None working" : "\(working) working",
                     tone: room.n == 0 ? .bad : (room.n <= 3 ? .warn : .ok),
                     fraction: limit == 0 ? 1 : Double(working) / Double(limit),
                     number: "\(working) of \(limit) lanes")
    }

    static func restartMeter(_ r: RestartAdvice) -> Meter {
        Meter(label: "Restart", word: r.word, tone: r.tone, fraction: r.fraction, number: r.number)
    }

    static func heat(thermal: Int?, smc: SMCReading?) -> Heat {
        let fans = smc?.fans ?? []
        let chip = smc?.chipCelsius
        let fanFraction = fans.map(\.fraction).max()
        let fanWord: String
        if fans.isEmpty { fanWord = "fan speed unavailable" }
        else if let f = fanFraction, f < 0.10 { fanWord = "fans idle" }
        else if let f = fanFraction, f < 0.45 { fanWord = "fans spinning" }
        else { fanWord = "fans loud" }
        let rpm = fans.isEmpty ? "" : " (\(fans.map { String(Int($0.rpm.rounded())) }.joined(separator: " and ")) rpm)"
        let degrees = chip.map { "\(Int($0.rounded())) C" } ?? "degrees unavailable"

        var word = "Cool"
        var short = "Cool"
        var tone = Tone.ok
        if let level = thermal, level >= 2 {
            word = "Throttling"; short = "Too hot"; tone = .bad
        } else if let level = thermal, level == 1 {
            word = "Hot, slowing down"; short = "Hot"; tone = .warn
        } else if let c = chip, c >= 85 {
            word = "Hot, coping"; short = "Hot"; tone = .warn
        } else if let c = chip, c >= 70 {
            word = "Warm"; short = "Warm"; tone = .ok
        } else if thermal == nil && chip == nil {
            word = "Unknown"; short = "Unknown"; tone = .neutral
        }
        return Heat(thermalLevel: thermal, chipCelsius: chip, fans: fans, word: word, tone: tone,
                    detail: "\(degrees), \(fanWord)\(rpm)", short: short, fanWord: fanWord)
    }

    static func room(cpu: CPUReading?, memory: MemoryReading?, heat: Heat, claude: ClaudeReading) -> Room {
        // Size of one working Claude lane, measured from real processes on this Mac.
        var perLane = Verdict.fallbackLaneBytes
        var measured = false
        let workingSizes = claude.working.compactMap { $0.pid }.compactMap { claude.processes.footprintByPid[$0] }
        if !workingSizes.isEmpty {
            perLane = UInt64(Double(workingSizes.reduce(0, +)) / Double(workingSizes.count))
            measured = true
        } else {
            let big = claude.processes.footprintByPid.values.filter { $0 > 100 << 20 }
            if !big.isEmpty {
                perLane = UInt64(Double(big.reduce(0, +)) / Double(big.count))
                measured = true
            }
        }

        var notes: [String] = []
        var memorySlots = 0
        if let m = memory {
            let spare = max(0, m.freePercent - reservePercent)
            memorySlots = Int(Double(m.totalBytes) * Double(spare) / 100.0 / Double(perLane))
        }
        var cpuSlots = 0
        if let c = cpu {
            cpuSlots = max(0, Int((Double(c.coreCount) - c.coresWorth - 1.0) / coresPerLane))
        }
        var n = min(memorySlots, cpuSlots)
        var limiter = memorySlots <= cpuSlots ? "memory" : "CPU"
        var tone = Tone.ok
        var stop = false

        if let m = memory {
            if m.swapUsedBytes >= swapFullBytes { stop = true; notes.append("Swap is at \(gb(m.swapUsedBytes)) GB") }
            else if m.swapUsedBytes >= swapTightBytes { n /= 2; notes.append("Swap is at \(gb(m.swapUsedBytes)) GB") }
            if m.pressureLevel >= 2 { stop = true; notes.append("Memory pressure is high") }
        }
        if let level = heat.thermalLevel {
            if level >= 2 { stop = true; notes.append("The Mac is throttling") }
            else if level == 1 { n /= 2; notes.append("The Mac is running hot") }
        }
        if stop { n = 0 }
        if let c = cpu, c.busyPercent > 85 { notes.append("CPU is nearly full") }

        let label: String
        if n == 0 { tone = .bad; label = "Stop" }
        else if n <= 3 || !notes.isEmpty { tone = .warn; label = "Slow down" }
        else { label = "OK" }

        if let first = notes.first, tone != .ok { limiter = first }
        else { limiter = "Limited by \(limiter)" }
        return Room(n: n, tone: tone, label: label, limiter: limiter, perLaneBytes: perLane,
                    perLaneMeasured: measured, memorySlots: memorySlots, cpuSlots: cpuSlots, notes: notes)
    }
}

// MARK: - The poll

final class MachineModel: ObservableObject {
    @Published private(set) var snapshot: MachineSnapshot?

    private let queue = DispatchQueue(label: "tile.machine.poll", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let cpuReader = CPUReader()
    private let smc = SMC()
    private var tick = 0
    private var lanes: [Lane] = []
    private var lanesError: String?
    private var lanesLoaded = false
    private var processes = ClaudeProcesses(count: 0, totalFootprintBytes: 0, footprintByPid: [:])
    private var spend: Double?
    private var lanesBusy = false
    private var heldAdvice: Advice?
    private var heldSince = Date.distantPast

    /// Used by `--machine-snapshot` to draw a reading without starting the poll.
    func load(_ s: MachineSnapshot) { snapshot = s }

    var smcAvailable: Bool { smc != nil }
    var smcTempKeys: [String] { smc?.tempKeyNames ?? [] }

    /// Starts polling. Nothing runs while the panel is closed.
    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        tick = 0
        // The CPU number is the busy share between two reads, so the first read only primes it.
        _ = cpuReader.read()
        source.schedule(deadline: .now() + 0.6, repeating: 2.0, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Everything at once, for the `--machine-dump` proof mode. Blocks.
    func collectOnce(waitForLanes: Bool) -> MachineSnapshot {
        _ = cpuReader.read()
        Thread.sleep(forTimeInterval: 2.0)
        refreshSlow(synchronous: true)
        return build()
    }

    private func poll() {
        // Slow sources on a slower beat: process scan and lanes every 10 s, spend every 60 s.
        if tick % 5 == 0 { refreshSlow(synchronous: false, spend: tick % 30 == 0) }
        tick += 1
        let next = build()
        DispatchQueue.main.async { [weak self] in self?.snapshot = next }
    }

    private func refreshSlow(synchronous: Bool, spend refreshSpend: Bool = true) {
        processes = ProcessScanner.scanClaude()
        if refreshSpend { spend = SpendReader.today() }
        if synchronous {
            let result = LaneReader.read()
            lanes = result.lanes
            lanesError = result.error
            lanesLoaded = true
        } else if !lanesBusy {
            lanesBusy = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = LaneReader.read()
                self?.queue.async {
                    self?.lanes = result.lanes
                    self?.lanesError = result.error
                    self?.lanesLoaded = true
                    self?.lanesBusy = false
                }
            }
        }
    }

    private func build() -> MachineSnapshot {
        let cpu = cpuReader.read()
        let memory = MemoryReader.read()
        let heat = Verdict.heat(thermal: ThermalReader.level(), smc: smc?.read())
        let claude = ClaudeReading(lanes: lanes, processes: processes, spendToday: spend, lanesError: lanesError,
                              lanesLoaded: lanesLoaded)
        let room = Verdict.room(cpu: cpu, memory: memory, heat: heat, claude: claude)
        let advice = steady(Verdict.advice(cpu: cpu, memory: memory, heat: heat, room: room,
                                           apps: processes.topApps), now: Date())
        let uptime = Sysctl.uptimeSeconds()
        let restart = Verdict.restart(memory: memory, uptimeSeconds: uptime, working: claude.working.count)
        return MachineSnapshot(date: Date(), cpu: cpu, memory: memory, heat: heat, claude: claude, room: room,
                               advice: advice, restart: restart, uptimeSeconds: uptime)
    }

    /// A worse answer shows at once. A better one waits until it has held for `calmSeconds`.
    func steady(_ next: Advice, now: Date) -> Advice {
        if let held = heldAdvice, next.level < held.level, now.timeIntervalSince(heldSince) < Verdict.calmSeconds {
            return held
        }
        heldAdvice = next
        heldSince = now
        return next
    }
}
