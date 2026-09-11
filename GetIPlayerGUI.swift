import Cocoa
import Foundation

// MARK: - Model

/// A single programme returned by get_iplayer's --listformat output.
struct Programme {
    var index: String
    var pid: String
    var name: String
    var episode: String
    var channel: String
    var duration: String
    var desc: String
    var type: String
    var available: String
    var expires: String
    var categories: String
    var versions: String
    var mode: String
    var web: String
    var filename: String
    var thumbnail: String
    var timeadded: String
    var guidance: String

    var displayTitle: String {
        if !episode.isEmpty && episode != "-" {
            return "\(name) - \(episode)"
        }
        return name
    }
}

// MARK: - Process runner

/// Runs the get_iplayer binary and captures its output.
final class GetIPlayerRunner {
    let binaryPath: String
    private var runningProcess: Process?
    private let lock = NSLock()

    init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    /// Sends SIGINT (ctrl-c) to the running process so get_iplayer can clean up
    /// partial files gracefully. No-op when nothing is running.
    func stop() {
        lock.lock()
        let process = runningProcess
        lock.unlock()
        process?.interrupt()
    }

    /// Runs get_iplayer on a background queue. `onOutput` is called on the main
    /// thread with each chunk of output as it arrives (for live progress/logging).
    /// `completion` is called on the main thread with the full combined output.
    func run(arguments: [String], onOutput: ((String) -> Void)? = nil, completion: @escaping (String, Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.binaryPath)
            process.arguments = arguments

            self.lock.lock()
            self.runningProcess = process
            self.lock.unlock()

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            var output = ""
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.count > 0 {
                    if let s = String(data: data, encoding: .utf8) {
                        output += s
                        if let onOutput = onOutput {
                            DispatchQueue.main.async { onOutput(s) }
                        }
                    }
                }
            }

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    completion("Error launching get_iplayer: \(error.localizedDescription)", -1)
                }
                return
            }

            process.waitUntilExit()
            handle.readabilityHandler = nil
            self.lock.lock()
            self.runningProcess = nil
            self.lock.unlock()
            // Drain any remaining data
            let remaining = handle.readDataToEndOfFile()
            if remaining.count > 0, let s = String(data: remaining, encoding: .utf8) {
                output += s
                if let onOutput = onOutput {
                    DispatchQueue.main.async { onOutput(s) }
                }
            }

            DispatchQueue.main.async {
                completion(output, process.terminationStatus)
            }
        }
    }
}

/// Splits a stream of text into complete lines, calling `lineHandler` for each.
final class LineBuffer {
    private var buffer = ""

    func process(_ chunk: String, lineHandler: (String) -> Void) {
        buffer += chunk
        while let r = buffer.range(of: "\n") {
            let line = String(buffer[..<r.lowerBound])
            buffer = String(buffer[r.upperBound...])
            lineHandler(line)
        }
    }

    func flush(_ lineHandler: (String) -> Void) {
        if !buffer.isEmpty {
            lineHandler(buffer)
            buffer = ""
        }
    }
}

// MARK: - Main view controller

final class ViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {

    // MARK: UI elements
    private let searchField = NSSearchField()
    private let typePopup = NSPopUpButton()
    private let searchButton = NSButton()
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private let outputDirField = NSTextField()
    private let browseButton = NSButton()
    private let qualityPopup = NSPopUpButton()
    private let subtitlesCheckbox = NSButton(checkboxWithTitle: "Subtitles", target: nil, action: nil)
    private let recordButton = NSButton()
    private let pidField = NSTextField()
    private let recordPidButton = NSButton()
    private let pidRecursiveCheckbox = NSButton(checkboxWithTitle: "Record whole series (PID recursive)", target: nil, action: nil)

    // Recording flags
    private let forceCheckbox = NSButton(checkboxWithTitle: "Force", target: nil, action: nil)
    private let audioOnlyCheckbox = NSButton(checkboxWithTitle: "Audio-only", target: nil, action: nil)
    private let rawCheckbox = NSButton(checkboxWithTitle: "Raw", target: nil, action: nil)
    private let noResumeCheckbox = NSButton(checkboxWithTitle: "No-resume", target: nil, action: nil)
    private let verboseCheckbox = NSButton(checkboxWithTitle: "Verbose", target: nil, action: nil)
    private let customFlagsField = NSTextField()

    // Progress
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "0%")

    private let logView = NSTextView()
    private let logScroll = NSScrollView()

    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let stopButton = NSButton()

    // MARK: State
    private var programmes: [Programme] = []
    private var runner: GetIPlayerRunner!
    private var isBusy = false

    // MARK: Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 680))
        self.view = root
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Reference the installed get_iplayer binary. The /Applications/get_iplayer/
        // folder only contains wrapper scripts; the real binary is at /usr/local/bin.
        let binaryPath = "/usr/local/bin/get_iplayer"
        runner = GetIPlayerRunner(binaryPath: binaryPath)
        if !FileManager.default.fileExists(atPath: binaryPath) {
            appendLog("Warning: get_iplayer not found at \(binaryPath).")
        }
        // Default output directory
        let docs = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        outputDirField.stringValue = docs?.path ?? (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("recordings")
    }

    // MARK: UI construction

    private func buildUI() {
        let root = view

        // --- Top bar ---
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let searchLabel = NSTextField(labelWithString: "Search:")
        searchField.placeholderString = "Programme name or regex (e.g. Doctor Who)"
        searchField.delegate = self
        searchField.accessibilityLabel = "Search term"
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        typePopup.addItems(withTitles: ["tv", "radio", "all"])
        typePopup.selectItem(withTitle: "tv")
        typePopup.accessibilityLabel = "Programme type"

        searchButton.title = "Search"
        searchButton.bezelStyle = .rounded
        searchButton.target = self
        searchButton.action = #selector(searchTapped)

        refreshButton.title = "Refresh Cache"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        topBar.addArrangedSubview(searchLabel)
        topBar.addArrangedSubview(searchField)
        topBar.addArrangedSubview(typePopup)
        topBar.addArrangedSubview(searchButton)
        topBar.addArrangedSubview(refreshButton)
        topBar.addArrangedSubview(spinner)

        // --- Table ---
        let indexCol = NSTableColumn(identifier: .init("index"))
        indexCol.title = "Idx"
        indexCol.width = 45
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Programme"
        nameCol.width = 300
        let channelCol = NSTableColumn(identifier: .init("channel"))
        channelCol.title = "Channel"
        channelCol.width = 100
        let durationCol = NSTableColumn(identifier: .init("duration"))
        durationCol.title = "Duration"
        durationCol.width = 70
        let pidCol = NSTableColumn(identifier: .init("pid"))
        pidCol.title = "PID"
        pidCol.width = 120
        let typeCol = NSTableColumn(identifier: .init("type"))
        typeCol.title = "Type"
        typeCol.width = 60

        for col in [indexCol, nameCol, channelCol, durationCol, pidCol, typeCol] {
            tableView.addTableColumn(col)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.accessibilityLabel = "Search results"

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // --- Bottom controls ---
        let bottomBar = NSStackView()
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        let outLabel = NSTextField(labelWithString: "Output:")
        outputDirField.placeholderString = "Output directory"
        outputDirField.delegate = self
        outputDirField.accessibilityLabel = "Output directory"
        outputDirField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        browseButton.title = "Browse…"
        browseButton.bezelStyle = .rounded
        browseButton.target = self
        browseButton.action = #selector(browseTapped)

        let qualityLabel = NSTextField(labelWithString: "Quality:")
        qualityPopup.addItems(withTitles: ["default", "fhd", "hd", "sd", "web", "mobile", "high", "std", "med", "low"])
        qualityPopup.selectItem(withTitle: "default")
        qualityPopup.accessibilityLabel = "Recording quality"

        recordButton.title = "Download Selected"
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(recordTapped)

        bottomBar.addArrangedSubview(outLabel)
        bottomBar.addArrangedSubview(outputDirField)
        bottomBar.addArrangedSubview(browseButton)
        bottomBar.addArrangedSubview(qualityLabel)
        bottomBar.addArrangedSubview(qualityPopup)
        bottomBar.addArrangedSubview(recordButton)

        // --- Recording flags bar ---
        let flagsBar = NSStackView()
        flagsBar.orientation = .horizontal
        flagsBar.spacing = 10
        flagsBar.translatesAutoresizingMaskIntoConstraints = false

        let flagsLabel = NSTextField(labelWithString: "Flags:")
        flagsBar.addArrangedSubview(flagsLabel)
        for cb in [forceCheckbox, audioOnlyCheckbox, rawCheckbox, noResumeCheckbox, verboseCheckbox, subtitlesCheckbox] {
            cb.setButtonType(.switch)
            cb.font = NSFont.systemFont(ofSize: 12)
            flagsBar.addArrangedSubview(cb)
        }
        let customLabel = NSTextField(labelWithString: "Custom:")
        customFlagsField.placeholderString = "e.g. --force --audio-only"
        customFlagsField.delegate = self
        customFlagsField.accessibilityLabel = "Custom flags"
        customFlagsField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        flagsBar.addArrangedSubview(customLabel)
        flagsBar.addArrangedSubview(customFlagsField)

        // --- PID bar ---
        let pidBar = NSStackView()
        pidBar.orientation = .horizontal
        pidBar.spacing = 8
        pidBar.translatesAutoresizingMaskIntoConstraints = false

        let pidLabel = NSTextField(labelWithString: "Record by PID/URL:")
        pidField.placeholderString = "e.g. b0abcdef or https://www.bbc.co.uk/iplayer/episode/..."
        pidField.accessibilityLabel = "Record by PID or URL"
        pidField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        recordPidButton.title = "Download"
        recordPidButton.bezelStyle = .rounded
        recordPidButton.keyEquivalent = "\r"
        recordPidButton.target = self
        recordPidButton.action = #selector(recordPidTapped)

        pidBar.addArrangedSubview(pidLabel)
        pidBar.addArrangedSubview(pidField)
        pidBar.addArrangedSubview(recordPidButton)

        pidRecursiveCheckbox.setButtonType(.switch)
        pidRecursiveCheckbox.font = NSFont.systemFont(ofSize: 12)
        pidRecursiveCheckbox.toolTip = "If the PID is a series or brand PID, download every related episode. Requires a PID (not a URL)."
        pidBar.addArrangedSubview(pidRecursiveCheckbox)

        // --- Progress bar ---
        let progressBarRow = NSStackView()
        progressBarRow.orientation = .horizontal
        progressBarRow.spacing = 8
        progressBarRow.translatesAutoresizingMaskIntoConstraints = false

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.controlSize = .regular
        progressBar.accessibilityLabel = "Download progress"
        progressBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressLabel.accessibilityLabel = "Progress percentage"
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .right
        progressLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true

        let progressTitle = NSTextField(labelWithString: "Progress:")
        progressBarRow.addArrangedSubview(progressTitle)
        progressBarRow.addArrangedSubview(progressBar)
        progressBarRow.addArrangedSubview(progressLabel)

        // --- Log ---
        logView.isEditable = false
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.autoresizingMask = [.width]
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.accessibilityLabel = "Status"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Bottom bar: status label on the left, Stop button on the right.
        let footerBar = NSStackView()
        footerBar.orientation = .horizontal
        footerBar.spacing = 8
        footerBar.translatesAutoresizingMaskIntoConstraints = false

        stopButton.title = "Stop"
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.isEnabled = false
        stopButton.toolTip = "Gracefully stop the running get_iplayer process"

        footerBar.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerBar.addArrangedSubview(spacer)
        footerBar.addArrangedSubview(stopButton)

        // --- Layout ---
        root.addSubview(topBar)
        root.addSubview(scrollView)
        root.addSubview(bottomBar)
        root.addSubview(flagsBar)
        root.addSubview(pidBar)
        root.addSubview(progressBarRow)
        root.addSubview(logScroll)
        root.addSubview(footerBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.heightAnchor.constraint(equalToConstant: 300),

            bottomBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            flagsBar.topAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: 8),
            flagsBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            flagsBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            pidBar.topAnchor.constraint(equalTo: flagsBar.bottomAnchor, constant: 8),
            pidBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            pidBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            progressBarRow.topAnchor.constraint(equalTo: pidBar.bottomAnchor, constant: 10),
            progressBarRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            progressBarRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            logScroll.topAnchor.constraint(equalTo: progressBarRow.bottomAnchor, constant: 8),
            logScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            logScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            logScroll.bottomAnchor.constraint(equalTo: footerBar.topAnchor, constant: -6),

            footerBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footerBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footerBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
    }

    // MARK: Actions

    @objc private func searchTapped() {
        let term = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            appendLog("Please enter a search term.")
            announce("Please enter a search term.")
            return
        }
        let type = typePopup.titleOfSelectedItem ?? "tv"
        runSearch(term: term, type: type)
    }

    @objc private func refreshTapped() {
        let type = typePopup.titleOfSelectedItem ?? "tv"
        setBusy(true)
        appendLog("Refreshing \(type) cache…")
        runner.run(arguments: ["--refresh", "--type=\(type)"]) { [weak self] output, _ in
            guard let self = self else { return }
            self.appendLog(output)
            self.setBusy(false)
            self.statusLabel.stringValue = "Cache refreshed."
            self.announce("Cache refreshed.")
        }
    }

    /// Runs `get_iplayer --help` and shows the output in the log console.
    @objc func showHelp() {
        appendLog("Fetching get_iplayer help…")
        runner.run(arguments: ["--help"]) { [weak self] output, _ in
            guard let self = self else { return }
            self.appendLog(output)
            self.statusLabel.stringValue = "get_iplayer help loaded."
            self.announce("get_iplayer help loaded.")
        }
    }

    private func runSearch(term: String, type: String) {
        setBusy(true)
        statusLabel.stringValue = "Searching…"
        let listFormat = "<index>|<pid>|<name>|<episode>|<channel>|<duration>|<desc>|<type>|<available>|<expires>|<categories>|<versions>|<mode>|<web>|<filename>|<thumbnail>|<timeadded>|<guidance>"
        let args = ["--type=\(type)", "--listformat=\(listFormat)", term]
        appendLog("Searching for '\(term)' (type: \(type))…")
        runner.run(arguments: args) { [weak self] output, _ in
            guard let self = self else { return }
            self.appendLog(output)
            self.parseResults(output)
            self.setBusy(false)
            self.statusLabel.stringValue = "\(self.programmes.count) programme(s) found."
            self.announce("\(self.programmes.count) programme(s) found.")
        }
    }

    @objc private func recordTapped() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else {
            appendLog("Select one or more programmes to record.")
            announce("Select one or more programmes to record.")
            return
        }
        let indices = selectedRows.compactMap { row -> String? in
            guard row < programmes.count else { return nil }
            return programmes[row].index
        }
        record(indices: indices)
    }

    @objc private func recordPidTapped() {
        let pid = pidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty else {
            appendLog("Enter a PID or URL to record.")
            announce("Enter a PID or URL to record.")
            return
        }
        record(pids: [pid])
    }

    private func record(indices: [String]) {
        guard !indices.isEmpty else { return }
        var args: [String] = []
        args.append(contentsOf: indices)
        args.append("--get")
        appendCommonRecordArgs(&args)
        appendLog("Recording indices: \(indices.joined(separator: ", "))")
        runRecord(args: args)
    }

    private func record(pids: [String]) {
        guard !pids.isEmpty else { return }
        var args: [String] = []
        for p in pids {
            let cleaned = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("http") {
                // Only accept well-formed http(s) URLs.
                if let url = URL(string: cleaned), let scheme = url.scheme,
                   (scheme == "http" || scheme == "https") {
                    args.append("--url=\(cleaned)")
                    if pidRecursiveCheckbox.state == .on {
                        appendLog("Note: the whole-series option only applies to PIDs, not URLs.")
                    }
                } else {
                    appendLog("Warning: ignoring invalid URL: \(p)")
                }
            } else {
                // BBC PIDs are alphanumeric.
                if cleaned.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil {
                    args.append("--pid=\(cleaned)")
                    // --pid-recursive only applies with --pid (not --url).
                    if pidRecursiveCheckbox.state == .on {
                        args.append("--pid-recursive")
                    }
                } else {
                    appendLog("Warning: ignoring invalid PID: \(p)")
                }
            }
        }
        args.append("--get")
        appendCommonRecordArgs(&args)
        appendLog("Recording: \(pids.joined(separator: ", "))")
        runRecord(args: args)
    }

    private func appendCommonRecordArgs(_ args: inout [String]) {
        let outDir = outputDirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outDir.isEmpty {
            args.append("--output=\(outDir)")
        }
        let quality = qualityPopup.titleOfSelectedItem ?? "default"
        if quality != "default" {
            args.append("--quality=\(quality)")
        }
        // Selected flags
        if forceCheckbox.state == .on { args.append("--force") }
        if audioOnlyCheckbox.state == .on { args.append("--audio-only") }
        if rawCheckbox.state == .on { args.append("--raw") }
        if noResumeCheckbox.state == .on { args.append("--no-resume") }
        if verboseCheckbox.state == .on { args.append("--verbose") }
        if subtitlesCheckbox.state == .on { args.append("--subtitles") }
        // Custom flags (whitespace-separated), filtered to safe flag tokens only.
        let custom = customFlagsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            let tokens = custom.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let safe = tokens.filter { safeFlagToken($0) }
            if safe.count != tokens.count {
                appendLog("Warning: ignored unsafe custom flag(s).")
            }
            args.append(contentsOf: safe)
        }
        // Force progress display to be captured even though output is piped (not a terminal).
        args.append("--log-progress")
    }

    /// Only allow flag-like tokens made of safe characters. Rejects shell
    /// metacharacters and anything that isn't a `-`-prefixed flag.
    private func safeFlagToken(_ token: String) -> Bool {
        guard token.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=./")
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func runRecord(args: [String]) {
        setBusy(true)
        statusLabel.stringValue = "Recording…"
        progressBar.doubleValue = 0
        progressLabel.stringValue = "0%"

        let lineBuffer = LineBuffer()
        runner.run(arguments: args, onOutput: { [weak self] chunk in
            guard let self = self else { return }
            lineBuffer.process(chunk) { line in
                if self.isProgressLine(line) {
                    self.updateProgress(line)
                } else {
                    self.appendLog(line)
                }
            }
        }) { [weak self] _, _ in
            guard let self = self else { return }
            self.setBusy(false)
            self.progressBar.doubleValue = 100
            self.progressLabel.stringValue = "100%"
            self.statusLabel.stringValue = "Recording finished."
            self.announce("Recording finished.")
        }
    }

    // MARK: Progress parsing

    private func isProgressLine(_ line: String) -> Bool {
        return line.range(of: #"^\s*\d+(?:\.\d+)?% of ~"#, options: .regularExpression) != nil
    }

    private func updateProgress(_ line: String) {
        // Reset the bar when a new programme download begins.
        if line.contains("INFO: Downloading ") {
            progressBar.doubleValue = 0
            progressLabel.stringValue = "0%"
        }
        let pattern = #"^\s*(\d+(?:\.\d+)?)% of ~"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line),
              let pct = Double(line[range]) else { return }
        progressBar.doubleValue = pct
        progressLabel.stringValue = String(format: "%.1f%%", pct)
    }

    @objc private func browseTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose output directory for recordings"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirField.stringValue = url.path
        }
    }

    // MARK: Parsing

    private func parseResults(_ output: String) {
        var results: [Programme] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "|")
            guard parts.count >= 18 else { continue }
            guard Int(parts[0]) != nil else { continue }
            results.append(Programme(
                index: parts[0],
                pid: parts[1],
                name: parts[2],
                episode: parts[3],
                channel: parts[4],
                duration: parts[5],
                desc: parts[6],
                type: parts[7],
                available: parts[8],
                expires: parts[9],
                categories: parts[10],
                versions: parts[11],
                mode: parts[12],
                web: parts[13],
                filename: parts[14],
                thumbnail: parts[15],
                timeadded: parts[16],
                guidance: parts[17]
            ))
        }
        programmes = results
        tableView.reloadData()
    }

    // MARK: Logging

    private func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let attributed = NSAttributedString(string: "[\(timestamp)] \(text)\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor
        ])
        logView.textStorage?.append(attributed)
        logView.scrollToEndOfDocument(nil)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        searchButton.isEnabled = !busy
        refreshButton.isEnabled = !busy
        recordButton.isEnabled = !busy
        recordPidButton.isEnabled = !busy
        stopButton.isEnabled = busy
    }

    /// Gracefully stops the currently running get_iplayer process (SIGINT).
    @objc private func stopTapped() {
        appendLog("Stop requested — interrupting get_iplayer…")
        runner.stop()
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return programmes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < programmes.count, let col = tableColumn else { return nil }
        let prog = programmes[row]

        let identifier = col.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)
            ])
            return c
        }()

        var value = ""
        switch identifier.rawValue {
        case "index": value = prog.index
        case "name": value = prog.displayTitle
        case "channel": value = prog.channel
        case "duration": value = prog.duration
        case "pid": value = prog.pid
        case "type": value = prog.type
        default: value = ""
        }
        cell.textField?.stringValue = value
        return cell
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === searchField {
                searchTapped()
                return true
            }
            // Consume Return in these fields so the default "Download" button
            // doesn't fire unexpectedly while editing them. The PID field
            // intentionally keeps the default (Download-on-Return) behavior.
            if control === outputDirField || control === customFlagsField {
                return true
            }
        }
        return false
    }

    /// Gives keyboard focus to the search field (used as the initial first responder).
    func focusSearch() {
        if let w = view.window {
            w.makeFirstResponder(searchField)
        }
    }

    /// Announces a message to assistive technologies (VoiceOver).
    private func announce(_ message: String) {
        let userInfo = [
            NSAccessibility.Notification.UserInfoKey.announcement: message,
            NSAccessibility.Notification.UserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: userInfo)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var viewController: ViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        let vc = ViewController()
        viewController = vc
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "get_iplayer GUI"
        window.contentViewController = vc
        window.center()
        window.setFrameAutosaveName("GetIPlayerMainWindow")
        window.makeKeyAndOrderFront(nil)
        viewController.focusSearch()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Builds the app main menu. Without an Edit menu, standard editing actions
    /// (Cut/Copy/Paste/Select All) are unavailable, so text fields can't accept pastes.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About get_iplayer GUI", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide get_iplayer GUI", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit get_iplayer GUI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (provides Cut/Copy/Paste/Select All)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu (provides Cmd+M Minimize / Zoom)
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        // Help menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        let helpItem = NSMenuItem(title: "Print Get_iPlayer Help", action: #selector(ViewController.showHelp), keyEquivalent: "")
        helpItem.target = viewController
        helpMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
