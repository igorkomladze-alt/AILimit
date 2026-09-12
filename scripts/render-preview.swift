import AppKit
import SwiftUI
import AILimitsCore
@testable import AILimitsMac

// Offline marketing renderer. No real accounts, credentials, or requests.
private struct DemoVault: SecretVault {
    func save(secret: Data, account: String) throws { throw ProviderError.disconnected }
    func delete(account: String) throws { throw ProviderError.disconnected }
    func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
        throw ProviderError.disconnected
    }
}
private struct DemoNotifications: NotificationDelivering {
    @MainActor func requestPermission() async -> Bool { false }
    func authorizationGranted() async -> Bool { false }
    func deliver(_ event: AlertEvent) async throws {}
    func knownEventIDs() async -> Set<String> { [] }
    func removePending(ids: [String]) {}
}
private struct DemoProvider: UsageProvider {
    let id: ProviderID
    func fetch(connection: ConnectionID) async throws -> UsageSnapshot { sample(connection) }
}
private func sample(_ connection: ConnectionID) -> UsageSnapshot {
    let now = Date()
    func quota(_ id: String, _ title: String, _ percent: Decimal, _ hours: Double) -> UsageQuota {
        UsageQuota(id: id, title: title, scope: connection.provider == .codex ? "codex" : nil,
            value: .remainingPercent(percent), windowSeconds: connection.provider == .claude || id == "weekly" && connection.provider == .kimi ? nil : hours * 3600,
            resetsAt: now.addingTimeInterval(hours == 5 ? 3 * 3600 : 3 * 86400))
    }
    let quotas: [UsageQuota]
    switch connection.provider {
    case .claude: quotas = [quota("5h", "5 часов", 42, 5), quota("7d", "Неделя", 76, 168)]
    case .codex: quotas = [quota("codex.codex.primary", "Codex · 7 дней", 68, 168)]
    case .kimi: quotas = [quota("weekly", "Основная квота", 84, 168), quota("5h", "Окно", 57, 5)]
    case .zai: quotas = [quota("5h", "Coding Plan", 91, 5), quota("weekly", "Coding Plan", 19, 168)]
    case .openrouter: quotas = []
    }
    return UsageSnapshot(connection: connection, source: "demo", fetchedAt: now, quotas: quotas,
                         balanceUSD: connection.provider == .openrouter ? Decimal(string: "12.50") : nil)
}

private struct PreviewPanel: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            CompactPanelView(model: model)
            Text("DEMO DATA · ДЕМО-ДАННЫЕ")
                .font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SocialPreview: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 24) {
                Text("AI Limits")
                    .font(.system(size: 68, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                Text("Your AI quotas.\nOne compact menu.")
                    .font(.system(size: 32, weight: .medium)).foregroundStyle(Color.white.opacity(0.86))
                Text("Codex · Claude · Kimi\nZ.ai · OpenRouter · custom APIs")
                    .font(.system(size: 20)).foregroundStyle(Color.white.opacity(0.65)).lineSpacing(8)
                HStack(spacing: 12) {
                    Text("macOS").padding(.horizontal, 14).padding(.vertical, 8)
                    Text("Open source · MIT").padding(.horizontal, 14).padding(.vertical, 8)
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(red: 0.65, green: 0.9, blue: 0.82))
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Text("github.com/igorkomladze-alt/AILimit")
                    .font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.45))
            }.frame(width: 620, alignment: .leading)
            PreviewPanel(model: model)
                .environment(\.colorScheme, .dark)
                .scaleEffect(1.15)
                .frame(width: 340, height: 540)
        }
        .padding(.horizontal, 90)
        .frame(width: 1280, height: 640)
        .background(Color(red: 0.07, green: 0.10, blue: 0.13))
    }
}

@main
@MainActor
struct RenderPreview {
    static func main() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AILimits-media-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var envelope = AppEnvelope()
        for provider in ProviderID.allCases {
            let connection = ConnectionRecord(id: ConnectionID(provider: provider, generation: UUID()),
                                              source: .manualKey, verifiedIdentityHash: nil)
            envelope.connections[provider.rawValue] = .init(record: connection)
            envelope.snapshots[provider.rawValue] = .init(snapshot: sample(connection.id))
        }
        let state = AtomicStateFile(directory: temporary)
        try state.write(envelope)
        let providers = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, DemoProvider(id: $0) as any UsageProvider) })
        let model = AppModel(stateFile: state, alertFile: AlertStateFile(alertsIn: temporary),
            notifications: DemoNotifications(), systemEvents: SystemEvents(),
            codexServer: CodexServerController(locator: CodexExecutableLocator(candidates: []),
                home: temporary.appendingPathComponent("codex"), userHome: temporary.appendingPathComponent("foreign")),
            vault: DemoVault(), providers: providers)
        while !model.isRestored { try await Task.sleep(for: .milliseconds(10)) }
        for (name, scheme) in [("panel-light", ColorScheme.light), ("panel-dark", ColorScheme.dark)] {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            try write(PreviewPanel(model: model).environment(\.colorScheme, scheme),
                      to: output.appendingPathComponent(name + ".png"), scale: 3)
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try write(SocialPreview(model: model).environment(\.colorScheme, .dark),
                  to: output.appendingPathComponent("social-preview.png"), scale: 1)
        model.shutdown()
        print("Rendered offline previews with synthetic values")
    }
    static func write<V: View>(_ view: V, to url: URL, scale: CGFloat) throws {
        // NSHostingView is needed for native controls and ScrollView, which
        // ImageRenderer intentionally omits. The helper window is never shown.
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
