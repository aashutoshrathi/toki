import Foundation

func emailIdentifier(in json: [String: Any]) -> String? {
    if let email = firstString(in: json, keys: ["email", "accountEmail", "account_email"]),
       email.contains("@") {
        return email
    }

    if let username = firstString(in: json, keys: ["preferred_username", "username", "login"]),
       username.contains("@") {
        return username
    }

    for tokenKey in ["accessToken", "idToken", "identityToken"] {
        guard let token = firstString(in: json, keys: [tokenKey]),
              let claims = jwtPayload(token) else {
            continue
        }
        if let email = firstString(in: claims, keys: ["email", "preferred_username", "username", "upn"]),
           email.contains("@") {
            return email
        }
    }

    return nil
}

func emailAddress(in snapshot: AccountSnapshot) -> String? {
    if let email = snapshot.accountInfo.first(where: { $0.label == "Email" })?.value,
       email.contains("@") {
        return email
    }
    if snapshot.subtitle.contains("@") {
        return snapshot.subtitle
    }
    return nil
}

func organizationName(in snapshot: AccountSnapshot) -> String? {
    snapshot.accountInfo.first(where: { $0.label == "Org" })?.value
}

/// The label that names which workspace/home an account lives in, for the compact sub-cards a
/// grouped provider draws. Prefers an explicit organization, else the suffix of a generated
/// "Provider (workspace)" name (e.g. "Codex (work)" -> "work").
func workspaceLabel(in snapshot: AccountSnapshot) -> String? {
    if let org = organizationName(in: snapshot), !org.isEmpty {
        return org
    }
    let prefix = snapshot.provider.displayName
    guard snapshot.name.hasPrefix(prefix) else { return nil }
    let rest = snapshot.name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
    let inner = rest.dropFirst().dropLast()
    return inner.isEmpty ? nil : String(inner)
}

func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - payload.count % 4) % 4
    payload += String(repeating: "=", count: padding)
    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json
}
