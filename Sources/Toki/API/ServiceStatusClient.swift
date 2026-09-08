import Foundation

/// Reads provider health off the public Statuspage instances the providers already publish.
///
/// These endpoints are unauthenticated and identical in shape across every page Toki reads, so
/// one parser covers all of them and a new provider is a table entry in `ServiceStatusSource`.
enum ServiceStatusClient {
    static func fetch(sources: [ServiceStatusSource], checkedAt: Date = Date()) async -> [Provider: ServiceStatus] {
        await withTaskGroup(of: [Provider: ServiceStatus].self) { group in
            for source in sources {
                group.addTask { await fetch(source: source, checkedAt: checkedAt) }
            }
            var merged: [Provider: ServiceStatus] = [:]
            for await statuses in group {
                merged.merge(statuses) { _, latest in latest }
            }
            return merged
        }
    }

    static func fetch(source: ServiceStatusSource, checkedAt: Date = Date()) async -> [Provider: ServiceStatus] {
        do {
            let payload = try await requestJSON(url: source.summaryURL, headers: ["Accept": "application/json"])
            return parse(summary: payload, source: source, checkedAt: checkedAt)
        } catch {
            DiagnosticLogger.shared.record(
                .warning,
                component: "service_status",
                code: "fetch_failed",
                detail: "\(source.id): \(error.localizedDescription)"
            )
            return [:]
        }
    }

    static func parse(summary: Any, source: ServiceStatusSource, checkedAt: Date) -> [Provider: ServiceStatus] {
        guard let root = summary as? [String: Any] else { return [:] }
        let page = root["status"] as? [String: Any]
        let pageDescription = (page?["description"] as? String) ?? ""
        let pageLevel = (page?["indicator"] as? String).flatMap(ServiceStatusLevel.init(pageIndicator:))
        let components = (root["components"] as? [[String: Any]]) ?? []

        var statuses: [Provider: ServiceStatus] = [:]
        for (provider, prefixes) in source.componentPrefixes {
            let matched = components.compactMap { component -> (name: String, level: ServiceStatusLevel)? in
                guard let name = component["name"] as? String,
                      matches(name: name, prefixes: prefixes),
                      let status = component["status"] as? String,
                      let level = ServiceStatusLevel(componentStatus: status) else { return nil }
                return (name, level)
            }

            let level: ServiceStatusLevel
            var affected: [String] = []
            if let worst = matched.map(\.level).max() {
                level = worst
                affected = matched
                    .filter { $0.level.isDisrupted }
                    .sorted { $0.level > $1.level }
                    .map(\.name)
            } else if let pageLevel {
                // No component of this provider's own on the page (or none Toki understands):
                // the whole-page roll-up is the only signal, and it is better than nothing.
                level = pageLevel
            } else {
                continue
            }

            statuses[provider] = ServiceStatus(
                provider: provider,
                level: level,
                pageDescription: pageDescription.isEmpty ? level.label : pageDescription,
                affectedComponents: affected,
                pageURL: source.pageURL,
                checkedAt: checkedAt
            )
        }
        return statuses
    }

    private static func matches(name: String, prefixes: [String]) -> Bool {
        guard !prefixes.isEmpty else { return false }
        let normalized = name.lowercased()
        return prefixes.contains { normalized.hasPrefix($0) }
    }
}
