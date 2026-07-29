import AppKit
import SwiftUI

struct RemoteConnectSheet: View {
    @ObservedObject private var server = RemoteControlServer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Scan to connect")
                .font(.headline)
            Text(server.hostMode == .tailscale || server.companionAppMode == .hosted
                ? "Open this on a phone connected to your tailnet."
                : "Point your phone's camera at the code on the same network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let url = server.connectURL, let image = RemoteControlServer.qrImage(for: url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(url)
                    .font(.system(size: 11).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if let code = server.pairingCode {
                    VStack(spacing: 3) {
                        Text("Verification code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(code.prefix(3) + " " + code.suffix(3))
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("The server isn't reachable at this address right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}
