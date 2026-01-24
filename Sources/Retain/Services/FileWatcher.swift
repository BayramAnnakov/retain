import Foundation
import Combine

/// Watches directories for file changes using FSEvents
final class FileWatcher: ObservableObject {
    /// Published events when files change
    @Published private(set) var lastEvent: FileEvent?

    /// File event types
    enum FileEventType {
        case created
        case modified
        case deleted
    }

    /// A file change event
    struct FileEvent: Equatable {
        let url: URL
        let type: FileEventType
        let timestamp: Date

        static func == (lhs: FileEvent, rhs: FileEvent) -> Bool {
            lhs.url == rhs.url && lhs.type == rhs.type
        }
    }

    /// Callback for file changes
    typealias ChangeHandler = (FileEvent) -> Void

    private var streams: [FSEventStreamRef] = []
    private var changeHandlers: [URL: ChangeHandler] = [:]
    private let handlersLock = NSLock()  // Protects changeHandlers from concurrent access
    private let queue = DispatchQueue(label: "com.retain.filewatcher", qos: .utility)

    deinit {
        stopAll()
    }

    // MARK: - Watch Management

    /// Start watching a directory for changes
    func watch(
        directory: URL,
        extensions: [String]? = nil,
        onChange: @escaping ChangeHandler
    ) {
        let path = directory.path

        // Store handler (thread-safe)
        let handler: ChangeHandler = { [weak self] event in
            // Filter by extension if specified
            if let exts = extensions {
                guard exts.contains(event.url.pathExtension) else { return }
            }

            DispatchQueue.main.async {
                self?.lastEvent = event
                onChange(event)
            }
        }
        handlersLock.lock()
        changeHandlers[directory] = handler
        handlersLock.unlock()

        // Create FSEvents stream
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { (streamRef, clientCallbackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let clientInfo = clientCallbackInfo else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
                watcher.handleEvents(
                    numEvents: numEvents,
                    eventPaths: eventPaths,
                    eventFlags: eventFlags
                )
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // Latency in seconds
            flags
        ) else {
            print("Failed to create FSEventStream for \(path)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        streams.append(stream)

        print("Started watching: \(path)")
    }

    /// Watch Claude Code projects directory
    func watchClaudeCode(onChange: @escaping ChangeHandler) {
        // Use resolved path to handle symlinked directories
        let dir = ClaudeCodeParser.resolvedProjectsDirectory
        watch(directory: dir, extensions: ["jsonl"], onChange: onChange)
    }

    /// Watch Codex history file
    func watchCodex(onChange: @escaping ChangeHandler) {
        let dir = CodexParser.codexDirectory
        watch(directory: dir, extensions: ["jsonl"], onChange: onChange)
    }

    /// Watch OpenCode storage directory
    func watchOpenCode(onChange: @escaping ChangeHandler) {
        guard let dir = OpenCodeParser.openCodeDirectory else { return }
        watch(directory: dir, extensions: ["json"], onChange: onChange)
    }

    /// Watch Gemini CLI sessions directory
    func watchGeminiCLI(onChange: @escaping ChangeHandler) {
        guard let dir = GeminiCLIParser.geminiDirectory else { return }
        watch(directory: dir, extensions: ["json"], onChange: onChange)
    }

    /// Watch Copilot CLI sessions directory
    func watchCopilot(onChange: @escaping ChangeHandler) {
        guard let dir = CopilotCLIParser.copilotDirectory else { return }
        watch(directory: dir, extensions: ["jsonl"], onChange: onChange)
    }

    /// Watch Cursor storage directory
    func watchCursor(onChange: @escaping ChangeHandler) {
        guard let dir = CursorParser.workspaceStorageDirectory else { return }
        watch(directory: dir, extensions: ["vscdb"], onChange: onChange)
        // Also watch global storage for composer data
        if let globalDir = CursorParser.globalStorageDirectory {
            watch(directory: globalDir, extensions: ["vscdb"], onChange: onChange)
        }
    }

    /// Stop watching a specific directory
    func stop(directory: URL) {
        handlersLock.lock()
        changeHandlers.removeValue(forKey: directory)
        handlersLock.unlock()
        // Note: FSEventStream cleanup would need stream-to-directory mapping
    }

    /// Stop all watchers
    func stopAll() {
        for stream in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams.removeAll()
        handlersLock.lock()
        changeHandlers.removeAll()
        handlersLock.unlock()
        print("Stopped all file watchers")
    }

    // MARK: - Event Handling

    private func handleEvents(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
            return
        }

        for i in 0..<numEvents {
            let path = paths[i]
            let flags = eventFlags[i]
            let url = URL(fileURLWithPath: path)

            // Determine event type
            let eventType: FileEventType
            if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                eventType = .created
            } else if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                eventType = .deleted
            } else if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 ||
                      flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0 {
                eventType = .modified
            } else {
                continue // Skip other events
            }

            // Only process files (not directories)
            guard flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 else {
                continue
            }

            let event = FileEvent(
                url: url,
                type: eventType,
                timestamp: Date()
            )

            // Find matching handler by checking if path starts with watched directory
            // Thread-safe: copy handlers under lock, then call outside lock
            handlersLock.lock()
            let handlersCopy = changeHandlers
            handlersLock.unlock()

            for (watchedDir, handler) in handlersCopy {
                if path.hasPrefix(watchedDir.path) {
                    handler(event)
                    break
                }
            }
        }
    }
}

// MARK: - Convenience Extensions

extension FileWatcher {
    /// Watch all CLI tool directories
    func watchAllCLITools(onChange: @escaping ChangeHandler) {
        watchClaudeCode(onChange: onChange)
        watchCodex(onChange: onChange)
    }
}
