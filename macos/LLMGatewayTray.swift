// LLMGateway menu bar icon: shows whether the shared Ollama server is up and which model is loaded,
// and starts, stops or restarts it. Every app that uses the local model (LeadScout, TradeFlow's
// Sentinel, ...) talks to this one server. "Open Chat…" opens a window for chatting with a model.
// Built and installed by scripts/service.sh.
import AppKit
import SwiftUI

let env = ProcessInfo.processInfo.environment
let ollamaURL = env["LLMGATEWAY_OLLAMA_URL"] ?? "http://127.0.0.1:11434"
let serviceLabel = env["LLMGATEWAY_SERVICE_LABEL"] ?? "local.llmgateway.ollama"
let servicePlist = env["LLMGATEWAY_SERVICE_PLIST"] ?? ""
let logFile = env["LLMGATEWAY_LOG_FILE"] ?? ""
let settingsFile = env["LLMGATEWAY_SETTINGS_FILE"] ?? ""
let domain = "gui/\(getuid())"

struct LoadedModel {
    var name: String
    var bytes: Int64
    var expiresAt: Date?
}

struct Status {
    var reachable = false
    var version = ""
    var loaded: [LoadedModel] = []
    var installed: [String] = []
}

/// A chip glyph with a status dot cut into its top-right corner. Drawn on demand so the chip follows
/// the menu bar's light/dark appearance while the dot keeps its color.
func trayIcon(dot: NSColor) -> NSImage {
    let height: CGFloat = 18
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let symbol = NSImage(systemSymbolName: "cpu", accessibilityDescription: "LLMGateway")?.withSymbolConfiguration(config)
    let glyphSize = symbol?.size ?? NSSize(width: 16, height: 16)
    let badge: CGFloat = 7
    let width = 1 + glyphSize.width + 4

    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        let glyph = NSRect(x: 1, y: (height - glyphSize.height) / 2, width: glyphSize.width, height: glyphSize.height)
        if let symbol {
            let tinted = NSImage(size: glyphSize, flipped: false) { rect in
                symbol.draw(in: rect)
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: glyph)
        }
        let dotRect = NSRect(x: glyph.maxX - 3.5, y: height - badge - 1, width: badge, height: badge)
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        dot.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        return true
    }
    image.isTemplate = false
    return image
}

func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }

/// GET or POST to Ollama, waiting up to `timeout` seconds. Returns the parsed JSON object, or nil.
func ollama(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 2) -> [String: Any]? {
    guard let url = URL(string: ollamaURL + path) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let body {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    let done = DispatchSemaphore(value: 0)
    var result: [String: Any]? = nil
    URLSession.shared.dataTask(with: request) { data, response, _ in
        defer { done.signal() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else { return }
        result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }.resume()
    _ = done.wait(timeout: .now() + timeout + 0.5)
    return result
}

final class TrayController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var status = Status()
    var timer: Timer?
    let chatWindow = ChatWindowController()

    override init() {
        super.init()
        menu.delegate = self
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // Rebuild the menu each time it opens, with fresh status.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh(withInstalled: true)
        rebuild()
    }

    func rebuild() {
        menu.removeAllItems()
        header(status.reachable ? "Ollama \(status.version): running" : "Ollama: not running")
        if status.reachable {
            if status.loaded.isEmpty {
                header("No model loaded (loads on the next request)")
            }
            for model in status.loaded {
                let until = model.expiresAt.map { date -> String in
                    // Ollama reports a far-future expiry for keep_alive -1.
                    date.timeIntervalSinceNow > 365 * 86400 ? " · stays loaded"
                        : " · unloads \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))"
                } ?? ""
                header("Loaded: \(model.name) (\(gigabytes(model.bytes)))\(until)")
            }
        }
        menu.addItem(.separator())
        add("Open Chat…", #selector(openChat), "")
        menu.addItem(.separator())

        if status.reachable {
            for model in status.loaded {
                let entry = add("Unload \(model.name) (free its memory)", #selector(unloadModel(_:)), "")
                entry.representedObject = model.name
            }
            if !status.installed.isEmpty {
                let models = NSMenuItem(title: "Installed Models", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for name in status.installed {
                    let entry = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                    entry.isEnabled = false
                    sub.addItem(entry)
                }
                models.submenu = sub
                menu.addItem(models)
            }
            menu.addItem(.separator())
            add("Restart Ollama", #selector(restartService), "")
            add("Stop Ollama", #selector(stopService), "")
        } else {
            add("Start Ollama", #selector(startService), "")
        }
        add("Show Log", #selector(showLog), "l", enabled: !logFile.isEmpty)
        add("Edit Settings…", #selector(editSettings), "", enabled: !settingsFile.isEmpty)
        menu.addItem(.separator())
        add("Quit Menu Bar Icon", #selector(quit), "q")
    }

    func header(_ title: String) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        menu.addItem(entry)
    }

    @discardableResult
    func add(_ title: String, _ action: Selector, _ key: String, enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.isEnabled = enabled
        menu.addItem(entry)
        return entry
    }

    func refresh(withInstalled: Bool = false) {
        var next = Status()
        if let version = ollama("/api/version") {
            next.reachable = true
            next.version = version["version"] as? String ?? ""
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for model in (ollama("/api/ps")?["models"] as? [[String: Any]]) ?? [] {
                let expires = (model["expires_at"] as? String).flatMap { iso -> Date? in
                    // Ollama sends nanoseconds; trim to milliseconds for the parser.
                    let trimmed = iso.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
                    return parser.date(from: trimmed)
                }
                next.loaded.append(LoadedModel(
                    name: model["name"] as? String ?? "?",
                    bytes: (model["size_vram"] as? NSNumber)?.int64Value ?? (model["size"] as? NSNumber)?.int64Value ?? 0,
                    expiresAt: expires))
            }
            if withInstalled {
                next.installed = ((ollama("/api/tags")?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
            } else {
                next.installed = status.installed
            }
        }
        status = next
        updateIcon()
    }

    func updateIcon() {
        // Green: a model is in memory. Gray: running, nothing loaded. Red: not running.
        let dot: NSColor = !status.reachable ? .systemRed : status.loaded.isEmpty ? .systemGray : .systemGreen
        item.button?.image = trayIcon(dot: dot)
        let state = !status.reachable ? "not running"
            : status.loaded.isEmpty ? "running, no model loaded"
            : "running, \(status.loaded.map(\.name).joined(separator: ", ")) loaded"
        item.button?.toolTip = "Ollama (LLMGateway): \(state)"
    }

    @objc func unloadModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DispatchQueue.global().async { [weak self] in
            _ = ollama("/api/generate", body: ["model": name, "keep_alive": 0], timeout: 30)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    // Ollama is a launchd job: unloading stops it (until the next login), loading starts it.
    @objc func startService() { launchctl(["bootstrap", domain, servicePlist]) }
    @objc func stopService() { launchctl(["bootout", "\(domain)/\(serviceLabel)"]) }
    @objc func restartService() { launchctl(["kickstart", "-k", "\(domain)/\(serviceLabel)"]) }
    func launchctl(_ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
    }

    @objc func showLog() {
        NSWorkspace.shared.open([URL(fileURLWithPath: logFile)],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func editSettings() {
        NSWorkspace.shared.open([URL(fileURLWithPath: settingsFile)],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openChat() { chatWindow.show() }

    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Chat window

struct ChatMessage: Identifiable {
    let id = UUID()
    var role: String // "user" or "assistant"
    var content: String
    var thinking = ""
}

/// The conversation, streamed from Ollama's /api/chat. Kept while the window is closed; "New Chat" clears it.
final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var models: [String] = []
    @Published var thinkingModels: Set<String> = []
    @Published var model = UserDefaults.standard.string(forKey: "chatModel") ?? "" {
        didSet { UserDefaults.standard.set(model, forKey: "chatModel") }
    }
    @Published var think = false
    @Published var busy = false
    @Published var error: String?
    private var task: Task<Void, Never>?

    var canThink: Bool { thinkingModels.contains(model) }

    /// Fetches the installed models, and which of them can think (e.g. qwen3), off the main thread.
    func loadModels() {
        DispatchQueue.global().async {
            let names = ((ollama("/api/tags")?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
            let thinking = Set(names.filter { name in
                ((ollama("/api/show", body: ["model": name])?["capabilities"] as? [String]) ?? []).contains("thinking")
            })
            let loaded = ((ollama("/api/ps")?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            DispatchQueue.main.async {
                self.models = names
                self.thinkingModels = thinking
                if !names.contains(self.model) {
                    // Prefer a model already in memory, so the first reply doesn't wait for a load.
                    self.model = loaded.first(where: names.contains) ?? names.first ?? ""
                }
                if names.isEmpty { self.error = "No models found. Is Ollama running? (ollama pull qwen3:14b)" }
                else if self.error?.hasPrefix("No models") == true { self.error = nil }
            }
        }
    }

    @MainActor func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !model.isEmpty else { return }
        input = ""
        error = nil
        messages.append(ChatMessage(role: "user", content: text))
        let history = messages.map { ["role": $0.role, "content": $0.content] }
        messages.append(ChatMessage(role: "assistant", content: ""))
        busy = true
        task = Task { @MainActor in
            await self.stream(history: history)
            self.busy = false
        }
    }

    @MainActor func stop() { task?.cancel() }

    @MainActor func clear() {
        task?.cancel()
        messages = []
        error = nil
    }

    @MainActor private func stream(history: [[String: String]]) async {
        let index = messages.count - 1
        var body: [String: Any] = ["model": model, "messages": history, "stream": true]
        if canThink { body["think"] = think } // Sending "think" to a model that can't think is an error.
        do {
            var request = URLRequest(url: URL(string: ollamaURL + "/api/chat")!, timeoutInterval: 600)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            var failure = ""
            // Ollama streams one JSON object per line.
            for try await line in bytes.lines {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                    failure += line
                    continue
                }
                if let message = object["error"] as? String { throw ChatError(message: message) }
                if let message = object["message"] as? [String: Any], index < messages.count {
                    messages[index].content += message["content"] as? String ?? ""
                    messages[index].thinking += message["thinking"] as? String ?? ""
                }
            }
            if !ok { throw ChatError(message: failure.isEmpty ? "Ollama returned an error." : failure) }
        } catch is CancellationError {
        } catch let failure as URLError where failure.code == .cancelled {
        } catch let failure as URLError where failure.code == .cannotConnectToHost {
            error = "Can't reach Ollama at \(ollamaURL). Start it from the menu bar icon."
        } catch {
            self.error = (error as? ChatError)?.message ?? error.localizedDescription
        }
        // Drop a reply that never got any text, so it isn't sent back as history.
        if index < messages.count, messages[index].content.isEmpty, messages[index].thinking.isEmpty {
            messages.remove(at: index)
        }
    }
}

struct ChatError: Error { let message: String }

struct MessageRow: View {
    let message: ChatMessage
    let streaming: Bool

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 60)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !message.thinking.isEmpty {
                    DisclosureGroup(streaming && message.content.isEmpty ? "Thinking…" : "Thought process") {
                        Text(message.thinking.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                if message.content.isEmpty && streaming {
                    ProgressView().controlSize(.small)
                } else {
                    Text(markdown(message.content.trimmingCharacters(in: .whitespacesAndNewlines)))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct ChatView: View {
    @ObservedObject var chat: ChatModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Model", selection: $chat.model) {
                    ForEach(chat.models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Toggle("Think", isOn: $chat.think)
                    .disabled(!chat.canThink)
                    .help(chat.canThink ? "Let the model reason before answering (slower)" : "This model can't think")
                Spacer()
                Button("New Chat") { chat.clear(); inputFocused = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(chat.messages.isEmpty)
            }
            .padding(10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { message in
                            MessageRow(message: message, streaming: chat.busy && message.id == chat.messages.last?.id)
                                .id(message.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: chat.messages.last?.content) { _ in
                    if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .overlay {
                    if chat.messages.isEmpty {
                        Text("Chat with \(chat.model.isEmpty ? "a local model" : chat.model)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = chat.error {
                Text(error)
                    .font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message (Return to send, Option-Return for a new line)", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .onSubmit { chat.send() }
                if chat.busy {
                    Button("Stop") { chat.stop() }.keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Send") { chat.send() }
                        .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.model.isEmpty)
                }
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { inputFocused = true }
    }
}

/// The chat window. While it's open the app shows in the Dock and Cmd-Tab like a normal app; when it
/// closes the app goes back to living only in the menu bar.
final class ChatWindowController: NSObject, NSWindowDelegate {
    let chat = ChatModel()
    var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "LLMGateway Chat"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ChatView(chat: chat))
            window.center()
            window.setFrameAutosaveName("LLMGatewayChat")
            window.delegate = self
            self.window = window
        }
        chat.loadModels()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Without a main menu, Cmd-C / Cmd-V / Cmd-A / Cmd-W do nothing in the chat window.
func installMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Hide LLMGateway", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
installMainMenu()
let controller = TrayController()
app.run()
