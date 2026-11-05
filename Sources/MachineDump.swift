import AppKit
import SwiftUI

/// `--machine-snapshot <dir>`: draws the real view with one real reading, once in dark and
/// once in light, and writes dark.png and light.png. For checking the look without a screen grab.
enum MachineSnapshotWriter {
    @MainActor static func run(into dir: String) {
        let model = MachineModel()
        model.load(model.collectOnce(waitForLanes: true))
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            let view = MachineView(model: model, onClose: {}, detailsOverride: true)
                .environment(\.colorScheme, scheme).padding(16)
                .background(scheme == .dark ? Color.black : Color(white: 0.8))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("render failed for \(name)"); continue
            }
            try? png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
            print("wrote \(dir)/\(name).png")
        }
    }

    /// `--machine-states <dir>`: every answer the tile can give, side by side, from samples.
    @MainActor static func runStates(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, scheme) in [("states-dark", ColorScheme.dark), ("states-light", ColorScheme.light)] {
            let columns = Array(repeating: GridItem(.fixed(272), spacing: 18, alignment: .top), count: 3)
            let sheet = LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(MachineSamples.sheet, id: \.0) { label, snap in
                    let model = MachineModel()
                    let _ = model.load(snap)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sample: \(label)").font(.system(size: 11, weight: .medium))
                            .foregroundColor(scheme == .dark ? .white : .black)
                        MachineView(model: model, onClose: {}, detailsOverride: false)
                    }
                }
            }
            .frame(width: 272 * 3 + 36)
            .environment(\.colorScheme, scheme).padding(20)
            .background(scheme == .dark ? Color.black : Color(white: 0.8))
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("render failed for \(name)"); continue
            }
            try? png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
            print("wrote \(dir)/\(name).png")
        }
    }
}

/// Made-up readings pushed through the real verdict code. For the state sheet and the rule
/// checks only: nothing here reaches the live panel.
enum MachineSamples {
    static func snapshot(busy: Double, free: Int, pressure: Int = 1, swapGB: Double, thermal: Int = 0,
                         chip: Double, working: Int, waiting: Int = 0, days: Double = 1.5) -> MachineSnapshot {
        let gb: UInt64 = 1 << 30
        let total = 24 * gb
        let cpu = CPUReading(busyPercent: busy, coresWorth: 18 * busy / 100, coresHot: Int(18 * busy / 100), coreCount: 18)
        let memory = MemoryReading(totalBytes: total, usedBytes: total / 100 * UInt64(100 - free), wiredBytes: 5 * gb,
                                   compressedBytes: 6 * gb, freePercent: free, pressureLevel: pressure,
                                   swapUsedBytes: UInt64(swapGB * Double(gb)),
                                   swapTotalBytes: UInt64((swapGB + 1) * Double(gb)))
        let fan = SMCReading.Fan(rpm: chip >= 85 ? 4200 : 1400, minRPM: 1350, maxRPM: 5500)
        let heat = Verdict.heat(thermal: thermal, smc: SMCReading(chipCelsius: chip, chipSensorCount: 65, fans: [fan, fan]))
        func lanes(_ n: Int, _ state: Lane.State, _ name: String) -> [Lane] {
            (0..<n).map { Lane(id: "\(name)\($0)", name: "\(name) \($0 + 1)", state: state, isBackground: true,
                               startedAt: Date().addingTimeInterval(-1800), pid: nil) }
        }
        let apps = [AppUse(name: "Node tools", bytes: gb * 7), AppUse(name: "Google Chrome", bytes: gb * 31 / 10),
                    AppUse(name: "Claude", bytes: gb * 27 / 10), AppUse(name: "Claude Code", bytes: gb * 13 / 10)]
        let claude = ClaudeReading(lanes: lanes(working, .working, "working lane") + lanes(waiting, .waiting, "sample lane"),
                                   processes: ClaudeProcesses(count: working, totalFootprintBytes: 0, footprintByPid: [:], topApps: apps),
                                   spendToday: nil, lanesError: nil, lanesLoaded: true)
        let room = Verdict.room(cpu: cpu, memory: memory, heat: heat, claude: claude)
        return MachineSnapshot(date: Date(), cpu: cpu, memory: memory, heat: heat, claude: claude, room: room,
                               advice: Verdict.advice(cpu: cpu, memory: memory, heat: heat, room: room, apps: apps),
                               restart: Verdict.restart(memory: memory, uptimeSeconds: days * 86400, working: working),
                               uptimeSeconds: days * 86400)
    }

    static let sheet: [(String, MachineSnapshot)] = [
        ("Quiet Mac", snapshot(busy: 12, free: 62, swapGB: 1.2, chip: 58, working: 1)),
        ("Hot, plenty of memory", snapshot(busy: 58, free: 45, swapGB: 3, chip: 91, working: 6)),
        ("Memory tight, lanes running", snapshot(busy: 30, free: 40, swapGB: 9.5, chip: 66, working: 3)),
        ("Memory tight, nothing running", snapshot(busy: 8, free: 44, swapGB: 9, chip: 52, working: 0)),
        ("Memory full", snapshot(busy: 45, free: 14, pressure: 2, swapGB: 15.5, chip: 74, working: 4, waiting: 2)),
        ("Throttling", snapshot(busy: 96, free: 38, swapGB: 4, thermal: 2, chip: 101, working: 9)),
    ]
}

/// `MachineTile --machine-dump`: runs the exact same readers and verdict code the panel
/// uses, once, and prints every number as plain `key: value` lines. This exists so each
/// number on the tile can be checked against the matching command-line tool.
enum MachineDump {
    static func run() {
        let model = MachineModel()
        let snap = model.collectOnce(waitForLanes: true)
        func gb(_ b: UInt64) -> String { String(format: "%.2f", Double(b) / 1_073_741_824.0) }

        print("smc_available: \(model.smcAvailable)")
        print("smc_temp_sensors_found: \(model.smcTempKeys.count)")
        if let c = snap.cpu {
            print("cpu_busy_percent: \(String(format: "%.1f", c.busyPercent))")
            print("cpu_cores_worth: \(String(format: "%.2f", c.coresWorth))")
            print("cpu_cores_over_half_busy: \(c.coresHot)")
            print("cpu_core_count: \(c.coreCount)")
        }
        if let m = snap.memory {
            print("mem_total_gb: \(gb(m.totalBytes))")
            print("mem_used_gb: \(gb(m.usedBytes))")
            print("mem_wired_gb: \(gb(m.wiredBytes))")
            print("mem_compressed_gb: \(gb(m.compressedBytes))")
            print("mem_free_percent: \(m.freePercent)")
            print("mem_pressure_level: \(m.pressureLevel)")
            print("swap_used_mb: \(String(format: "%.2f", Double(m.swapUsedBytes) / 1_048_576.0))")
            print("swap_total_mb: \(String(format: "%.2f", Double(m.swapTotalBytes) / 1_048_576.0))")
            print("swap_percent: \(String(format: "%.1f", m.swapFraction * 100))")
        }
        print("thermal_level: \(snap.heat.thermalLevel.map(String.init) ?? "unavailable")")
        print("chip_celsius_hottest: \(snap.heat.chipCelsius.map { String(format: "%.2f", $0) } ?? "unavailable")")
        for (i, f) in snap.heat.fans.enumerated() {
            print("fan\(i)_rpm: \(Int(f.rpm)) min \(Int(f.minRPM)) max \(Int(f.maxRPM))")
        }
        print("heat_word: \(snap.heat.word)")
        print("heat_detail: \(snap.heat.detail)")

        let c = snap.claude
        print("claude_lanes_error: \(c.lanesError ?? "none")")
        print("claude_working: \(c.working.count)")
        print("claude_waiting: \(c.waiting.count)")
        print("claude_idle: \(c.idle.count)")
        print("claude_done_hidden: \(c.lanes.filter { $0.state == .done }.count)")
        print("claude_waiting_newest: \(c.waiting.prefix(3).map(\.name).joined(separator: ", "))")
        print("claude_process_count: \(c.processes.count)")
        print("claude_process_total_gb: \(gb(c.processes.totalFootprintBytes))")
        print("spend_today_usd: \(c.spendToday.map { String(format: "%.2f", $0) } ?? "unavailable")")

        print("advice_level: \(snap.advice.level)")
        print("advice_title: \(snap.advice.title)")
        print("advice_why: \(snap.advice.why)")
        print("restart_word: \(snap.restart.word)")
        print("restart_number: \(snap.restart.number)")
        var meters = [Verdict.heatMeter(snap.heat), Verdict.claudeMeter(snap.claude, room: snap.room), Verdict.restartMeter(snap.restart)]
        if let c = snap.cpu { meters.append(Verdict.workloadMeter(c)) }
        if let m = snap.memory { meters.append(Verdict.memoryMeter(m)) }
        for m in meters { print("meter: \(m.label) | \(m.word) | \(m.number) | \(m.fraction.map { String(format: "%.2f", $0) } ?? "no bar")") }
        print("restart_note: \(snap.restart.note ?? "none")")
        print("uptime_days: \(snap.uptimeSeconds.map { String(format: "%.2f", $0 / 86400) } ?? "unavailable")")
        for app in c.processes.topApps { print("top_app: \(app.name) \(gb(app.bytes)) GB") }

        let r = snap.room
        print("room_n: \(r.n)")
        print("room_label: \(r.label)")
        print("room_limiter: \(r.limiter)")
        print("room_memory_slots: \(r.memorySlots)")
        print("room_cpu_slots: \(r.cpuSlots)")
        print("room_lane_mb: \(r.perLaneBytes >> 20) (\(r.perLaneMeasured ? "measured" : "assumed"))")
        print("room_notes: \(r.notes.joined(separator: "; "))")
        let pids = c.working.compactMap(\.pid)
        print("working_lane_pids: \(pids.map(String.init).joined(separator: " "))")
    }
}
