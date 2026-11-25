import Foundation

extension UsageStore {
    func setAgentPopoverVisible(_ visible: Bool) {
        guard agentPopoverVisible != visible else { return }
        agentPopoverVisible = visible
        scheduleAgentRefresh()
        if visible {
            // Opening is an explicit request for current data, not a reason to wait for the timer.
            refreshActiveAgents()
        }
    }

    func scheduleAgentRefresh() {
        let needsFrequentRefresh = agentPopoverVisible || agentRemoteControlIsRunning()
            || activeAgents.contains(where: \.needsInput)
        let interval: TimeInterval = needsFrequentRefresh ? 15 : 60
        // A scan or unrelated state change must not restart the current interval.
        guard agentTimer?.timeInterval != interval else { return }
        agentTimer?.invalidate()
        agentTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshActiveAgents(manual: false)
            }
        }
    }

    func refreshActiveAgents(manual: Bool = true) {
        // Serialize scans: a slow scan must not overlap the next tick, or two detached
        // tasks would race the scanner's PID cache. Timer ticks coalesce by skipping;
        // an explicit request retains one follow-up so it cannot be lost.
        guard !isScanningAgents else {
            if manual { agentRefreshAfterCurrent = true }
            return
        }
        isScanningAgents = true
        Task {
            let scanned = await agentScan()
            let previous = activeAgents
            let previousAwaitingInput = previous.filter(\.needsInput).count
            let previouslyNeededInput = previous.contains(where: \.needsInput)
            if scanned != previous {
                activeAgents = scanned
            }
            isScanningAgents = false
            if scanned.filter(\.needsInput).count != previousAwaitingInput {
                writeWidgetData(for: snapshots)
            }
            if previouslyNeededInput != scanned.contains(where: \.needsInput) {
                scheduleAgentRefresh()
            }
            if agentRefreshAfterCurrent {
                agentRefreshAfterCurrent = false
                refreshActiveAgents(manual: false)
            }
        }
    }

    // Daily activity is read from each tool's own session store, which means touching a lot of
    // files, so it is scanned off the main actor and only when the window it covers could have
    // changed - not on every popover open.
    func refreshDailyActivity(force: Bool = false) {
        guard !isScanningActivity else { return }
        let window = min(30, max(preferences.historyRetentionDays, 1))
        if !force, let scanned = dailyActivityScannedAt, Date().timeIntervalSince(scanned) < 300 { return }
        isScanningActivity = true
        Task {
            let outcome = await DailyActivityScanner.scan(dayCount: window)
            unreadableActivityProviders = outcome.unreadable
            // A scan that read nothing at all leaves the previous data in place rather than
            // replacing it with an empty chart. Clobbering it would turn a transient read
            // failure into "you have no history", and the throttle below would then pin that
            // wrong answer on screen for five minutes.
            if !outcome.isCompleteFailure {
                dailyActivity = outcome.activities
                dailyActivityScannedAt = Date()
            }
            isScanningActivity = false
        }
    }

    // Drops the row immediately for a responsive feel, then reconciles with a real scan
    // shortly after in case the signal didn't actually take effect (e.g. no permission).
    func terminateAgent(_ agent: ActiveAgent) {
        guard agent.canTerminate else { return }
        ActiveAgentTerminator.terminate(agent)
        activeAgents.removeAll { $0.id == agent.id }
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshActiveAgents()
        }
    }
}
