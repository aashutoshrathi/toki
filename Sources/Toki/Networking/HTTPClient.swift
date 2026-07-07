import Foundation

func requestJSON(url: URL, headers: [String: String]) async throws -> Any {
    var request = URLRequest(url: url)
    request.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }

    await MainActor.run { debugLogHandler?("GET \(url.path)") }

    let (data, response) = try await URLSession.shared.data(for: request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? ""
    await MainActor.run { debugLogHandler?("\(statusCode) \(url.path) - \(bodyPreview.prefix(80))") }

    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        throw HTTPStatusError(statusCode: http.statusCode, body: body)
    }
    return try JSONSerialization.jsonObject(with: data)
}
