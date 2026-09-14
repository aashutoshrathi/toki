import AppKit
import SwiftUI

// Embedded in the Settings route; Done returns to management without stopping sessions.
struct RemoteConnectSheet: View {
    @ObservedObject private var server = RemoteControlServer.shared
    var onDone: () -> Void
    @State private var copiedCode = false
    @State private var copiedLink = false

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 8) {
                    Text(server.hostMode == .tailscale || server.companionAppMode == .hosted
                        ? "Scan with a phone connected to your tailnet."
                        : "Scan with your phone on the same network.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let url = server.connectURL, let image = RemoteControlServer.qrImage(for: url) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 160, height: 160)
                            .padding(8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Connection QR code. Use Copy link below as an alternative.")
                        Text(url)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let code = server.pairingCode {
                            Button {
                                copy(code)
                                copiedCode = true
                            } label: {
                                VStack(spacing: 3) {
                                    Text("Verification code").font(.system(size: 11)).foregroundStyle(.secondary)
                                    Text(code.prefix(3) + " " + code.suffix(3))
                                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                    Text(copiedCode ? "Copied" : "Copy code")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(copiedCode ? "Verification code copied" : "Copy verification code \(code)")
                            if let expiresAt = server.pairingCodeExpiresAt {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let remaining = max(0, expiresAt.timeIntervalSince(context.date))
                                    Text("New code in \(Int(remaining.rounded()))s")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                        .foregroundStyle(remaining <= 20 ? .orange : .secondary)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("Connection unavailable", systemImage: "wifi.slash",
                                               description: Text("Return to Remote Control to check the server and its address."))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    guard let url = server.connectURL else { return }
                    copy(url)
                    copiedLink = true
                } label: {
                    Label(copiedLink ? "Copied" : "Copy link", systemImage: copiedLink ? "checkmark" : "doc.on.doc")
                }
                .disabled(server.connectURL == nil)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
        }
        .onChange(of: server.pairingCode) { copiedCode = false }
        .onChange(of: server.connectURL) { copiedLink = false }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
