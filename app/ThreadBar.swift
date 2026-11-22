// ThreadBar: a menu bar overview of every Claude Code thread across your projects.
// It runs the bundled threads.py (read-only) every minute and shows the result.
// Click the menu bar icon or press Hyper+; (Caps Lock+;, i.e. ⌃⌥⇧⌘;) anywhere. Type to filter, ↑/↓ to move, Enter to open, Esc to close.
import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Model

struct ThreadRow: Decodable, Identifiable {
    let id: String
    let title: String
    let project: String
    let state: String
    let unread: Bool
    let needs_action: String
    let recent_action: String
    let updated_at: String?
    let url: String       // claude:// deep link (desktop app)
    let web_url: String?  // https link (browser)

    var note: String { state == "blocked" && !needs_action.isEmpty ? needs_action : recent_action }
    var updated: Date? {
        guard let s = updated_at else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

let stateOrder = ["blocked", "failed", "working", "review_ready", "completed", "unknown"]
let stateLabel = ["blocked": "Needs you", "failed": "Failed", "working": "Working",
                  "review_ready": "Ready for review", "completed": "Done", "unknown": "Other"]
let stateColor: [String: Color] = ["blocked": .orange, "failed": .red, "working": .blue,
                                   "review_ready": .purple, "completed": .secondary, "unknown": .secondary]

// MARK: - Log (next to the source, so problems are easy to inspect)

enum Log {
    static let url: URL? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/claude-thread-overview", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            return dir.appendingPathComponent("threadbar.log")
        }
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return logs.appendingPathComponent("ThreadBar.log")
    }()

    static func write(_ msg: String) {
        guard let url else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(msg)\n"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 300_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var rows: [ThreadRow] = []
    @Published var error: String?
    @Published var lastRefresh: Date?
    @Published var loading = false
    @Published var focusToken = 0
    @Published var doneDays: Int = UserDefaults.standard.object(forKey: "doneDays") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(doneDays, forKey: "doneDays") }
    }
    private var timer: Timer?
    private var known: [String: String] = [:]

    init() {
        Log.write("ThreadBar started")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var needsYou: Int { rows.filter { $0.state == "blocked" || $0.state == "failed" }.count }
    var working: Int { rows.filter { $0.state == "working" }.count }

    func refresh() {
        guard !loading else { return }
        loading = true
        let days = doneDays
        Task.detached {
            let result = Store.runScript(days: days)
            await MainActor.run {
                self.loading = false
                self.lastRefresh = Date()
                switch result {
                case .success(let rows):
                    self.error = nil
                    self.chimeOnChanges(rows)
                    self.rows = rows
                case .failure(let msg):
                    self.error = msg
                }
            }
        }
    }

    private func chimeOnChanges(_ new: [ThreadRow]) {
        defer { known = Dictionary(new.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        guard !known.isEmpty else { return }
        let flipped = new.contains { r in
            guard let old = known[r.id] else { return false }
            return old != r.state && ["blocked", "completed", "review_ready", "failed"].contains(r.state)
        }
        if flipped { NSSound(named: "Glass")?.play() }
    }

    enum Outcome { case success([ThreadRow]), failure(String) }

    nonisolated static func runScript(days: Int) -> Outcome {
        guard let script = Bundle.main.path(forResource: "threads", ofType: "py") else {
            Log.write("ERROR threads.py missing from bundle")
            return .failure("threads.py is missing from the app bundle.")
        }
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("threadbar-stderr.txt")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script, "--json", "--days", String(days)]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = try? FileHandle(forWritingTo: errURL)
        let started = Date()
        do { try p.run() } catch {
            Log.write("ERROR could not start python3: \(error.localizedDescription)")
            return .failure("Couldn't start python3: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let errText = ((try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        if p.terminationStatus != 0 {
            Log.write("ERROR exit \(p.terminationStatus) after \(secs)s; stderr: \(errText.prefix(600))")
            return .failure(errText.isEmpty ? "threads.py exited with \(p.terminationStatus)" : String(errText.prefix(300)))
        }
        do {
            let rows = try JSONDecoder().decode([ThreadRow].self, from: data)
            Log.write("ok: \(rows.count) rows, \(data.count) bytes, \(secs)s" + (errText.isEmpty ? "" : "; stderr: \(errText.prefix(300))"))
            return .success(rows)
        } catch {
            let head = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            Log.write("ERROR decode: \(error) ; stdout head: \(head) ; stderr: \(errText.prefix(300))")
            return .failure("Couldn't read the thread list (details in threadbar.log).")
        }
    }
}

// MARK: - Global hotkey (Carbon; needs no Accessibility permission)

final class HotKey {
    nonisolated(unsafe) static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5442_4152), id: 1)  // 'TBAR'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        Log.write(status == noErr ? "hotkey Hyper+; registered" : "hotkey registration failed (\(status))")
    }
}

// MARK: - Views

func ago(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = Date().timeIntervalSince(d)
    if s >= 86400 { return "\(Int(s / 86400))d" }
    if s >= 3600 { return "\(Int(s / 3600))h" }
    if s >= 60 { return "\(Int(s / 60))m" }
    return "now"
}

struct RowView: View {
    let row: ThreadRow
    let selected: Bool
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(row.unread ? Color.accentColor : .clear).frame(width: 6, height: 6)
                    Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(ago(row.updated)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Color.clear.frame(width: 6, height: 1)
                    Text(row.project).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if !row.note.isEmpty {
                        Text(row.note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(
                selected ? Color.accentColor.opacity(0.22) : (hover ? Color.primary.opacity(0.07) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(row.note)
    }
}

struct Panel: View {
    @ObservedObject var store: Store
    let close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var filterFocused: Bool

    private var groups: [(state: String, rows: [ThreadRow])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = q.isEmpty ? store.rows : store.rows.filter {
            "\($0.title) \($0.project) \($0.note)".lowercased().contains(q)
        }
        return stateOrder.compactMap { st in
            let r = matching.filter { $0.state == st }
            return r.isEmpty ? nil : (st, r)
        }
    }
    private var flat: [ThreadRow] { groups.flatMap { $0.rows } }

    // Click / Enter opens the thread in the Claude desktop app; hold ⌘ to open it in the browser.
    private func open(_ row: ThreadRow) {
        let web = NSEvent.modifierFlags.contains(.command)
        let link = web ? (row.web_url ?? row.url) : row.url
        guard let u = URL(string: link) else { close(); return }
        // A plain open() of a claude.ai https link gets picked up by the desktop app, so hand it
        // straight to the default browser.
        if web, let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) {
            NSWorkspace.shared.open([u], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(u)
        }
        close()
    }

    private func move(_ d: Int) {
        let n = flat.count
        guard n > 0 else { return }
        selected = max(0, min(n - 1, selected + d))
    }

    var body: some View {
        let groups = self.groups
        let flat = groups.flatMap { $0.rows }
        let index = Dictionary(flat.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let listHeight = min(520, max(60, CGFloat(flat.count) * 44 + CGFloat(groups.count) * 30 + 12))

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter threads", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($filterFocused)
                    .onSubmit { if flat.indices.contains(selected) { open(flat[selected]) } }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { _, _ in selected = 0 }
                if store.loading { ProgressView().controlSize(.small) }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()

            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if flat.isEmpty {
                            Text(store.loading && store.rows.isEmpty ? "Loading threads…"
                                 : (query.isEmpty ? "Nothing open." : "No threads match."))
                                .foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(groups, id: \.state) { g in
                            HStack(spacing: 6) {
                                Circle().fill(stateColor[g.state] ?? .secondary).frame(width: 7, height: 7)
                                Text("\(stateLabel[g.state] ?? g.state)  \(g.rows.count)")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                            ForEach(g.rows) { row in
                                RowView(row: row, selected: index[row.id] == selected) { open(row) }
                                    .padding(.horizontal, 4)
                                    .id(row.id)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(height: listHeight)
                .onChange(of: selected) { _, new in
                    if flat.indices.contains(new) { proxy.scrollTo(flat[new].id) }
                }
            }

            Divider()
            HStack(spacing: 10) {
                Picker("Done from last", selection: $store.doneDays) {
                    Text("Done: 1 day").tag(1); Text("Done: 3 days").tag(3); Text("Done: 7 days").tag(7)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .onChange(of: store.doneDays) { _, _ in store.refresh() }
                Text("⇪; · ↑↓ · ↩ app · ⌘↩ web").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let t = store.lastRefresh {
                    Text(t.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Menu {
                    Toggle("Open at login", isOn: Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { on in
                            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                            catch { Log.write("login item: \(error)") }
                        }))
                    Divider()
                    Button("Quit ThreadBar") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 440)
        .onAppear { filterFocused = true }
        .onChange(of: store.focusToken) { _, _ in
            query = ""
            selected = 0
            filterFocused = true
        }
    }
}

// MARK: - App shell (status item + popover, so the hotkey can open it)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var hotKey: HotKey?
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(toggle)
            b.imagePosition = .imageLeading
        }
        popover.behavior = .transient
        popover.animates = false
        let panel = Panel(store: store, close: { [weak self] in self?.popover.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: panel)

        store.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.updateButton() } }
            .store(in: &bag)
        updateButton()

        hotKey = HotKey(keyCode: kVK_ANSI_Semicolon, modifiers: cmdKey | controlKey | optionKey | shiftKey) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
    }

    @objc func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        store.focusToken += 1
    }

    func updateButton() {
        guard let b = statusItem?.button else { return }
        let symbol: String
        if store.error != nil {
            symbol = "exclamationmark.bubble"
        } else if store.needsYou > 0 {
            symbol = "bubble.left.and.exclamationmark.bubble.right.fill"
        } else if store.working > 0 {
            symbol = "bubble.left.and.text.bubble.right"
        } else {
            symbol = "bubble.left.and.bubble.right"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude threads")
        img?.isTemplate = true
        b.image = img
        b.title = store.needsYou > 0 ? " \(store.needsYou)" : ""
        b.toolTip = store.error ?? "Claude threads: \(store.needsYou) need you, \(store.working) working (Hyper+;)"
    }
}

@main
struct ThreadBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }
}
