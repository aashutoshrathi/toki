import Foundation

enum ClaudeCodeAccountDiscovery {
    private static let backupDir = "~/.claude-swap-backup"

    static func discover(config: AccountConfig, labels: [AccountLabelConfig]) -> [ClaudeCodeAccountRecord] {
        if let sequence = readSequence() {
            return records(from: sequence, labels: labels)
        }
        return [fallbackRecord(config: config, labels: labels)]
    }

    static func fallbackRecord(config: AccountConfig, labels: [AccountLabelConfig]) -> ClaudeCodeAccountRecord {
        do {
            let bundle = try ClaudeCodeCredentialReader.readCredentials(account: config)
            let email = ClaudeCodeCredentialReader.emailIdentifier(from: bundle.credentials)
            let orgName = ClaudeCodeCredentialReader.organizationName(from: bundle.credentials)
            let orgUUID = ClaudeCodeCredentialReader.organizationUUID(from: bundle.credentials)
            return ClaudeCodeAccountRecord(
                id: config.id,
                name: config.name,
                email: email,
                organizationName: orgName,
                organizationUUID: orgUUID,
                accountNumber: nil,
                isActive: true,
                source: bundle.source,
                credentials: bundle.credentials,
                loadError: nil,
                label: resolveLabel(email: email, organizationName: orgName, organizationUUID: orgUUID, labels: labels)
            )
        } catch {
            return ClaudeCodeAccountRecord(
                id: config.id,
                name: config.name,
                email: nil,
                organizationName: nil,
                organizationUUID: nil,
                accountNumber: nil,
                isActive: true,
                source: "Claude Code Keychain",
                credentials: nil,
                loadError: error.localizedDescription,
                label: nil
            )
        }
    }

    private static func records(from sequence: ClaudeSwapSequence, labels: [AccountLabelConfig]) -> [ClaudeCodeAccountRecord] {
        let orderedNumbers = sequence.sequence ?? sequence.accounts.keys.compactMap(Int.init).sorted()
        return orderedNumbers.compactMap { number in
            guard let metadata = sequence.accounts["\(number)"] else { return nil }
            let active = sequence.activeAccountNumber == number
            let credentialResult = credentials(for: number, metadata: metadata, active: active)
            return ClaudeCodeAccountRecord(
                id: "claude-\(number)-\(metadata.email)",
                name: metadata.email,
                email: metadata.email,
                organizationName: metadata.organizationName,
                organizationUUID: metadata.organizationUuid,
                accountNumber: number,
                isActive: active,
                source: credentialResult.source,
                credentials: credentialResult.credentials,
                loadError: credentialResult.error,
                label: resolveLabel(
                    email: metadata.email,
                    organizationName: metadata.organizationName,
                    organizationUUID: metadata.organizationUuid,
                    labels: labels
                )
            )
        }
    }

    private static func resolveLabel(email: String?, organizationName: String?, organizationUUID: String?, labels: [AccountLabelConfig]) -> AccountPresentation? {
        guard let email else { return nil }
        let normalizedEmail = email.lowercased()
        let matches = labels.filter { $0.email.lowercased() == normalizedEmail }
        let match = matches.first(where: { label in
            label.organizationUuid != nil && label.organizationUuid == organizationUUID
        }) ?? matches.first(where: { label in
            label.organizationName != nil && label.organizationName == organizationName
        }) ?? matches.first(where: { label in
            label.organizationUuid == nil && label.organizationName == nil
        })

        guard let match else { return nil }
        return AccountPresentation(nickname: match.nickname, emoji: match.emoji, color: match.color)
    }

    private static func credentials(for number: Int, metadata: ClaudeSwapAccount, active: Bool) -> (credentials: String?, source: String, error: String?) {
        if active {
            do {
                let activeBundle = try ClaudeCodeCredentialReader.readMacOSKeychainCredentials()
                return (activeBundle.credentials, "\(activeBundle.source) active", nil)
            } catch {
                return (nil, "Claude Code Keychain active", error.localizedDescription)
            }
        }

        let keychainAccount = "account-\(number)-\(metadata.email)"
        do {
            let credentials = try ClaudeCodeCredentialReader.readKeychain(service: "claude-swap", account: keychainAccount)
            return (credentials, "claude-swap \(number)", nil)
        } catch {
            return (nil, "claude-swap \(number)", error.localizedDescription)
        }
    }

    private static func readSequence() -> ClaudeSwapSequence? {
        let path = expandedPath("\(backupDir)/sequence.json")
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder.toki.decode(ClaudeSwapSequence.self, from: data)
    }
}
