import SwiftUI

// The Machine Tile face. One answer on top, a row of plain words for each thing behind it,
// and every raw number under Details.
// Dark and light both come from the system appearance. Green, amber and rose are
// used for STATE only; the blue is the accent and never means a state.

private struct Palette {
    let dark: Bool
    var background: Color { dark ? Color(red: 0.055, green: 0.058, blue: 0.065) : Color(red: 0.975, green: 0.977, blue: 0.982) }
    var border: Color { dark ? Color(red: 0.16, green: 0.17, blue: 0.19) : Color(red: 0.86, green: 0.87, blue: 0.89) }
    var card: Color { dark ? Color(red: 0.094, green: 0.100, blue: 0.113) : Color.white }
    var text: Color { dark ? Color(red: 0.92, green: 0.93, blue: 0.95) : Color(red: 0.10, green: 0.11, blue: 0.13) }
    var muted: Color { dark ? Color(red: 0.58, green: 0.60, blue: 0.65) : Color(red: 0.40, green: 0.42, blue: 0.47) }
    var track: Color { dark ? Color(red: 0.17, green: 0.18, blue: 0.20) : Color(red: 0.90, green: 0.91, blue: 0.93) }
    /// The accent blue.
    var accent: Color { Color(red: 0.216, green: 0.514, blue: 0.941) }
    func state(_ tone: Tone) -> Color {
        switch tone {
        case .ok: return dark ? Color(red: 0.24, green: 0.80, blue: 0.47) : Color(red: 0.10, green: 0.58, blue: 0.31)
        case .warn: return dark ? Color(red: 0.98, green: 0.72, blue: 0.30) : Color(red: 0.76, green: 0.46, blue: 0.02)
        case .bad: return dark ? Color(red: 0.98, green: 0.39, blue: 0.45) : Color(red: 0.84, green: 0.18, blue: 0.27)
        case .neutral: return muted
        }
    }
}

private func gigabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f", Double(bytes) / 1_073_741_824.0)
}

private func age(_ date: Date?) -> String {
    guard let date else { return "" }
    let s = Int(Date().timeIntervalSince(date))
    if s < 3600 { return "\(max(1, s / 60))m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

struct MachineView: View {
    @ObservedObject var model: MachineModel
    var onClose: () -> Void
    var onResize: () -> Void
    /// Forces Details open or shut for the `--machine-states` sheet.
    var detailsOverride: Bool?
    @AppStorage("machineDetailsOpen") private var detailsOpen = false
    @Environment(\.colorScheme) private var scheme

    init(model: MachineModel, onClose: @escaping () -> Void, onResize: @escaping () -> Void = {},
         detailsOverride: Bool? = nil) {
        self.model = model
        self.onClose = onClose
        self.onResize = onResize
        self.detailsOverride = detailsOverride
    }

    private var p: Palette { Palette(dark: scheme == .dark) }
    private var open: Bool { detailsOverride ?? detailsOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let s = model.snapshot {
                verdict(s.advice)
                glance(s)
                detailsToggle
                if open { details(s) }
            } else {
                Text("Reading the machine...")
                    .font(.system(size: 11)).foregroundColor(p.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
            }
        }
        .padding(12)
        .frame(width: 272)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.background))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
    }

    // MARK: header and the one big answer

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(p.accent).frame(width: 6, height: 6)
            Text("Machine").font(.system(size: 11, weight: .semibold)).foregroundColor(p.text)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(p.muted)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (control option command M)")
        }
    }

    private func verdict(_ a: Advice) -> some View {
        let color = p.state(a.tone)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(a.title).font(.system(size: 20, weight: .semibold)).foregroundColor(p.text)
                    .minimumScaleFactor(0.7).lineLimit(1)
            }
            Text(a.why).font(.system(size: 11)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.55), lineWidth: 1))
    }

    // MARK: the glance rows

    private func meterRow(_ m: Meter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(m.label).font(.system(size: 11)).foregroundColor(p.muted).frame(width: 52, alignment: .leading)
                Text(m.word).font(.system(size: 12, weight: .semibold)).foregroundColor(p.text).lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(m.number).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    .foregroundColor(p.state(m.tone)).lineLimit(1)
            }
            if let fraction = m.fraction { bar(fraction, tone: m.tone) }
        }
    }

    private func glance(_ s: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            meterRow(Verdict.heatMeter(s.heat))
            if let c = s.cpu { meterRow(Verdict.workloadMeter(c)) }
            if let m = s.memory { meterRow(Verdict.memoryMeter(m)) }
            claudeGlance(s.claude, room: s.room)
            meterRow(Verdict.restartMeter(s.restart))
            if let note = s.restart.note { small(note) }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private func claudeGlance(_ c: ClaudeReading, room: Room) -> some View {
        if !c.lanesLoaded {
            meterRow(Meter(label: "Claude", word: "Checking", tone: .neutral, fraction: nil, number: ""))
        } else if c.lanesError != nil {
            meterRow(Meter(label: "Claude", word: "Unavailable", tone: .neutral, fraction: nil, number: ""))
        } else {
            meterRow(Verdict.claudeMeter(c, room: room))
            if !c.waiting.isEmpty { waitingList(c, limit: 2) }
        }
    }

    private func waitingList(_ c: ClaudeReading, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(c.waiting.count) waiting on you").font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(p.state(.bad))
            ForEach(c.waiting.prefix(limit)) { lane in
                HStack(spacing: 5) {
                    Circle().fill(p.state(.bad)).frame(width: 5, height: 5)
                    Text(lane.name).font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(p.state(.bad)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(age(lane.startedAt)).font(.system(size: 10)).foregroundColor(p.muted)
                }
            }
            if c.waiting.count > limit {
                small("and \(c.waiting.count - limit) more waiting")
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.state(.bad).opacity(0.10)))
    }

    // MARK: details

    private var detailsToggle: some View {
        Button {
            detailsOpen.toggle()
            onResize()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                Text(open ? "Hide details" : "Details").font(.system(size: 10.5, weight: .medium))
                Spacer()
            }
            .foregroundColor(p.muted).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func details(_ s: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            roomRow(s.room)
            heatRow(s.heat)
            cpuRow(s.cpu)
            memoryRow(s.memory)
            appsRow(s.claude.processes.topApps)
            claudeRow(s.claude)
        }
    }

    private func roomRow(_ room: Room) -> some View {
        row("Room") {
            big("Room for \(room.n) more")
            small("\(room.limiter). Memory allows \(room.memorySlots), CPU allows \(room.cpuSlots).")
            small("One Claude lane is about \(gigabytes(room.perLaneBytes)) GB\(room.perLaneMeasured ? ", measured" : ", assumed")")
        }
    }

    @ViewBuilder private func appsRow(_ apps: [AppUse]) -> some View {
        if !apps.isEmpty {
            row("Biggest apps") {
                ForEach(apps, id: \.name) { app in
                    HStack {
                        small(app.name)
                        Spacer(minLength: 6)
                        small("\(gigabytes(app.bytes)) GB")
                    }
                }
            }
        }
    }

    // MARK: rows

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.6).foregroundColor(p.accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ fraction: Double, tone: Tone) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(p.track)
                Capsule().fill(p.state(tone)).frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 4)
    }

    private func big(_ text: String, color: Color? = nil) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(color ?? p.text)
    }

    private func small(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func heatRow(_ heat: Heat) -> some View {
        row("Heat") {
            big(heat.word, color: p.state(heat.tone))
            small(heat.detail)
            small("Macs slow themselves down before heat can do damage.")
        }
    }

    private func cpuRow(_ cpu: CPUReading?) -> some View {
        row("CPU") {
            if let c = cpu {
                let tone: Tone = c.busyPercent > 85 ? .bad : (c.busyPercent > 60 ? .warn : .ok)
                big("\(Int(c.busyPercent.rounded()))% busy")
                bar(c.busyPercent / 100, tone: tone)
                small("\(c.coresHot) of \(c.coreCount) cores working hard")
            } else {
                small("Measuring...")
            }
        }
    }

    private func memoryRow(_ m: MemoryReading?) -> some View {
        row("Memory") {
            if let m {
                let usedFraction = Double(m.usedBytes) / Double(m.totalBytes)
                let memTone: Tone = m.pressureLevel >= 4 ? .bad : (m.pressureLevel >= 2 ? .warn : .ok)
                big("\(gigabytes(m.usedBytes)) of \(gigabytes(m.totalBytes)) GB used")
                bar(usedFraction, tone: memTone)
                let pressure = m.pressureLevel >= 4 ? "critical" : (m.pressureLevel >= 2 ? "high" : "normal")
                small("Pressure \(pressure), \(m.freePercent)% free")
                let swapTone: Tone = m.swapUsedBytes >= Verdict.swapFullBytes ? .bad
                    : (m.swapUsedBytes >= Verdict.swapTightBytes ? .warn : .ok)
                HStack(spacing: 6) {
                    small("Swap \(gigabytes(m.swapUsedBytes)) of \(gigabytes(m.swapTotalBytes)) GB")
                    bar(m.swapFraction, tone: swapTone).frame(width: 60)
                    Text("\(Int((m.swapFraction * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundColor(p.state(swapTone))
                }
                small("Swap is memory overflow kept on disk. It works, but slower.")
            } else {
                small("Measuring...")
            }
        }
    }

    private func claudeRow(_ c: ClaudeReading) -> some View {
        row("Claude") {
            if !c.lanesLoaded {
                small("Asking Claude what it is doing...")
            } else if let err = c.lanesError {
                small("Lane list unavailable: \(err)")
            } else {
                let working = c.working.count, waiting = c.waiting.count
                big(working == 0 ? "Nothing working" : "\(working) working",
                    color: working == 0 ? p.muted : p.text)
                small("\(waiting) waiting on you, \(c.idle.count) idle")
                if waiting > 2 { waitingList(c, limit: 6) }
            }
            if let spend = c.spendToday {
                small("Spend today about $\(String(format: "%.2f", spend)) (list price)")
            }
            small("\(c.processes.count) Claude processes, \(gigabytes(c.processes.totalFootprintBytes)) GB")
        }
    }
}
