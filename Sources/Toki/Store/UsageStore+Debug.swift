import Foundation

extension UsageStore {
    func logDebug(_ message: String) {
        guard debugMode else { return }
        debugLog.append(DebugLogEntry(timestamp: Date(), message: message))
        if debugLog.count > 100 {
            debugLog.removeFirst(debugLog.count - 100)
        }
    }

    func toggleDebug() {
        debugMode.toggle()
        if debugMode {
            debugLogHandler = { [weak self] in self?.logDebug($0) }
            logDebug("Debug mode enabled")
        } else {
            debugLogHandler = nil
        }
    }
}
