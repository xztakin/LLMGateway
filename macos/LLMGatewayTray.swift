// LLMGateway menu bar icon: shows whether the shared Ollama server is up and which model is loaded,
// and starts, stops or restarts it. Every app that uses the local model (LeadScout, TradeFlow's
// Sentinel, ...) talks to this one server.
// Built and installed by scripts/service.sh.
import AppKit

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

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let controller = TrayController()
app.run()
