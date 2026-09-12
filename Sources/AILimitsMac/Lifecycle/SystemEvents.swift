import Foundation
import AppKit
import Network
import AILimitsCore

/// Task 6, шаг 6: системные события — сон/пробуждение и восстановление сети.
/// willSleep → приостановка; didWake + NWPath available → одно объединённое обновление
/// (debounce), без воспроизведения пропущенных пятиминутных циклов.
///
/// Весь класс MainActor-isolated: NSWorkspace-нотификации и NWPath handler доставляются
/// через DispatchQueue.main, что соответствует изоляции.
@MainActor
public final class SystemEvents: ObservableObject {
    /// Callback координатору: слить в одно обновление.
    public var onWake: (() -> Void)?
    /// Callback при засыпании: остановить фоновые helper-процессы.
    public var onSleep: (() -> Void)?

    private var wakeObserver: (any NSObjectProtocol)?
    private var sleepObserver: (any NSObjectProtocol)?
    private var pathMonitor: NWPathMonitor?
    /// Debounce: одно объединённое обновление при серии событий.
    private var wakeDebounce: DispatchWorkItem?
    /// Приостановлен ли опрос (сон).
    public private(set) var suspended = false

    public init() {}

    nonisolated public func start() {
        MainActor.assumeIsolated {
            self.startOnMain()
        }
    }

    private func startOnMain() {
        let workspace = NSWorkspace.shared
        sleepObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suspended = true
                self?.onSleep?()
            }
        }
        wakeObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWake() }
        }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor [weak self] in self?.handleWake() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    /// Пробуждение/восстановление сети: debounce-слияние в одно обновление.
    private func handleWake() {
        suspended = false
        wakeDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.onWake?() }
        }
        wakeDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    nonisolated public func stop() {
        MainActor.assumeIsolated {
            self.stopOnMain()
        }
    }

    private func stopOnMain() {
        let workspace = NSWorkspace.shared
        if let sleepObserver { workspace.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { workspace.notificationCenter.removeObserver(wakeObserver) }
        pathMonitor?.cancel()
        wakeDebounce?.cancel()
    }
}
