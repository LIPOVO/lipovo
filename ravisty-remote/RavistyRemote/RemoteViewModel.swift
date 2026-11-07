import Foundation
import SwiftUI
import UIKit

@MainActor
final class RemoteViewModel: ObservableObject {
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "tvHost") } }
    @Published var portText: String { didSet { UserDefaults.standard.set(portText, forKey: "tvPort") } }
    @Published private(set) var status = "Подключитесь к телевизору в одной сети Wi-Fi."
    @Published private(set) var device = "BQ · Рависты TV"
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var fastInput = false
    @Published private(set) var lastInputLatencyMS: Int?
    @Published private(set) var screenshot: UIImage?
    @Published var showScreenshot = false
    private let adb = ADBClient()
    private let inputADB = ADBClient()
    private var utilityReady = false
    private var connectedHost = ""
    private var connectedPort: UInt16 = 5555
    private var generation = 0
    private var connectionTask: Task<Void, Never>?
    private var keyTask: Task<Void, Never>?
    private var utilityTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var wantsConnection = false
    private var isInBackground = false
    private var pendingKeys = RemoteKeyBuffer(capacity: 3, lifetime: 0.350)

    init() {
        host = UserDefaults.standard.string(forKey: "tvHost") ?? "192.168.0.121"
        portText = UserDefaults.standard.string(forKey: "tvPort") ?? "5555"
    }

    func connect() {
        guard !busy else { return }
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && (Int(part).map { (0...255).contains($0) } ?? false)
        }), let port = UInt16(portText), port > 0 else {
            status = ADBError.invalidAddress.localizedDescription
            return
        }
        host = address
        wantsConnection = true
        guard !isInBackground else { return }
        generation += 1
        let session = generation
        let previousKey = keyTask
        let previousUtility = utilityTask
        let previousTeardown = teardownTask
        previousKey?.cancel()
        previousUtility?.cancel()
        keyTask = nil
        utilityTask = nil
        pendingKeys.removeAll()
        busy = true
        connected = false
        fastInput = false
        utilityReady = false
        lastInputLatencyMS = nil
        connectedHost = address
        connectedPort = port
        connectionTask = Task {
            defer {
                if session == generation { busy = false; connectionTask = nil }
            }
            do {
                await previousTeardown?.value
                try Task.checkCancellation()
                await adb.disconnect()
                await inputADB.disconnect()
                // Let cancelled operations finish their actor cleanup before reusing clients.
                await previousKey?.value
                await previousUtility?.value
                try Task.checkCancellation()
                _ = try await adb.connect(host: address, port: port) { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, session == self.generation, self.busy, !self.connected else { return }
                        self.status = message
                    }
                }
                try Task.checkCancellation()
                guard session == generation else { return }
                utilityReady = true
                let info = try await adb.shell("getprop ro.product.model; getprop ro.build.version.release")
                let lines = info.split(whereSeparator: \.isNewline).map(String.init)
                if lines.count >= 2 { device = "\(lines[lines.count - 2]) · Android \(lines.last!)" }
                try Task.checkCancellation()
                _ = try await inputADB.connect(host: address, port: port) { _ in }
                try Task.checkCancellation()
                do {
                    try await inputADB.startInputSession()
                    fastInput = true
                } catch {
                    // A TV without our helper keeps the standard ADB input fallback.
                    // No key was sent yet, so reconnecting here cannot duplicate a tap.
                    try Task.checkCancellation()
                    _ = try await inputADB.connect(host: address, port: port) { _ in }
                    fastInput = false
                }
                try Task.checkCancellation()
                guard session == generation else { return }
                connected = true
                status = fastInput ? "Телевизор подключён. Быстрый пульт готов." : "Телевизор подключён. Стандартный режим пульта."
            } catch {
                guard session == generation else { return }
                connected = false; utilityReady = false
                if !(error is CancellationError) { status = error.localizedDescription }
                await adb.disconnect()
                await inputADB.disconnect()
            }
        }
    }

    func disconnect() {
        closeConnection(keepIntent: false)
    }

    func enterBackground() {
        guard !isInBackground else { return }
        isInBackground = true
        if wantsConnection { closeConnection(keepIntent: true) }
    }

    func enterForeground() {
        guard isInBackground else { return }
        isInBackground = false
        guard wantsConnection else { return }
        let closing = teardownTask
        Task {
            await closing?.value
            guard !isInBackground, wantsConnection, !connected, connectionTask == nil else { return }
            connect()
        }
    }

    private func closeConnection(keepIntent: Bool) {
        if !keepIntent { wantsConnection = false }
        generation += 1
        let session = generation
        let previousConnection = connectionTask
        let previousKey = keyTask
        let previousUtility = utilityTask
        let previousTeardown = teardownTask
        previousConnection?.cancel()
        connectionTask = nil
        previousKey?.cancel()
        previousUtility?.cancel()
        keyTask = nil
        utilityTask = nil
        pendingKeys.removeAll()
        connected = false
        fastInput = false
        utilityReady = false
        busy = true
        status = "Отключено."
        teardownTask = Task {
            await adb.disconnect()
            await inputADB.disconnect()
            await previousConnection?.value
            await previousKey?.value
            await previousUtility?.value
            await previousTeardown?.value
            if session == generation { busy = false }
        }
    }

    func key(_ keyCode: Int, label: String) {
        guard connected else { return }
        pendingKeys.append(code: keyCode, label: label, now: ProcessInfo.processInfo.systemUptime)
        guard keyTask == nil else { return }
        let session = generation
        keyTask = Task {
            defer { if session == generation { keyTask = nil } }
            while session == generation, connected, !Task.isCancelled,
                  let next = pendingKeys.next(now: ProcessInfo.processInfo.systemUptime) {
                do {
                    if fastInput { try await inputADB.keyEvent(next.code) }
                    else { _ = try await inputADB.shell("input keyevent \(next.code)") }
                    guard session == generation else { return }
                    lastInputLatencyMS = Int((ProcessInfo.processInfo.systemUptime - next.submittedAt) * 1000)
                    status = next.label
                } catch {
                    guard session == generation else { return }
                    // Never replay a possibly applied key after a broken acknowledgement.
                    pendingKeys.removeAll()
                    connected = false
                    fastInput = false
                    status = error.localizedDescription
                    await inputADB.disconnect()
                    await adb.disconnect()
                    utilityReady = false
                    return
                }
            }
        }
    }

    func launch(_ app: RemoteApp) {
        run(label: app.name,
            command: "am start -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER -p \(app.package)")
    }

    private func run(label: String, command: String) {
        guard connected, !busy else { return }
        let session = generation
        busy = true
        utilityTask = Task {
            defer { if session == generation { busy = false; utilityTask = nil } }
            do {
                try await ensureUtilityConnection(session: session)
                let response = try await adb.shell(command)
                guard session == generation else { return }
                if response.localizedCaseInsensitiveContains("Error:")
                    || response.localizedCaseInsensitiveContains("Exception") {
                    status = String(response.prefix(250))
                } else {
                    status = label
                }
            } catch {
                guard session == generation else { return }
                utilityReady = false
                status = error.localizedDescription
            }
        }
    }

    private func ensureUtilityConnection(session: Int) async throws {
        guard session == generation else { throw CancellationError() }
        if utilityReady { return }
        _ = try await adb.connect(host: connectedHost, port: connectedPort) { _ in }
        guard session == generation else { throw CancellationError() }
        utilityReady = true
    }

    func takeScreenshot() {
        guard connected, !busy else { return }
        let session = generation
        busy = true
        status = "Получаю снимок экрана…"
        utilityTask = Task {
            defer { if session == generation { busy = false; utilityTask = nil } }
            do {
                try await ensureUtilityConnection(session: session)
                let bytes = try await adb.screenshot()
                guard session == generation else { return }
                guard let image = UIImage(data: bytes) else { throw ADBError.missingPNG }
                screenshot = image
                showScreenshot = true
                status = "Снимок получен."
            } catch {
                guard session == generation else { return }
                utilityReady = false
                status = error.localizedDescription
            }
        }
    }
}

struct RemoteApp: Identifiable {
    let name: String
    let package: String
    let symbol: String
    let tint: Color
    var id: String { package }
    static let favorites: [RemoteApp] = [
        .init(name: "Рависты TV", package: "tv.ravisty.launcher", symbol: "star.fill", tint: .ravistyRed),
        .init(name: "YouTube", package: "com.google.android.youtube.tv", symbol: "play.rectangle.fill", tint: Color(red: 0.95, green: 0.23, blue: 0.28)),
        .init(name: "Кинопоиск", package: "ru.kinopoisk.tv", symbol: "film.fill", tint: .orange),
        .init(name: "VK Видео", package: "com.vk.tv", symbol: "play.tv.fill", tint: .blue),
        .init(name: "Wink", package: "ru.rt.video.app.tv", symbol: "tv.fill", tint: Color(red: 1, green: 0.34, blue: 0.22))
    ]
}
