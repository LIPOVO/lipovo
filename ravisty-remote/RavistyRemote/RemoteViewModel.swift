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
    @Published private(set) var screenshot: UIImage?
    @Published var showScreenshot = false
    private let adb = ADBClient()

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
        busy = true
        connected = false
        Task {
            do {
                _ = try await adb.connect(host: address, port: port) { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.busy, !self.connected else { return }
                        self.status = message
                    }
                }
                connected = true
                status = "Телевизор подключён. Пульт готов."
                let info = try await adb.shell("getprop ro.product.model; getprop ro.build.version.release")
                let lines = info.split(whereSeparator: \.isNewline).map(String.init)
                if lines.count >= 2 { device = "\(lines[lines.count - 2]) · Android \(lines.last!)" }
            } catch {
                connected = false
                status = error.localizedDescription
            }
            busy = false
        }
    }

    func disconnect() {
        Task { await adb.disconnect() }
        connected = false
        status = "Отключено."
    }

    func key(_ keyCode: Int, label: String) {
        run(label: label, command: "input keyevent \(keyCode)")
    }

    func launch(_ app: RemoteApp) {
        run(label: app.name,
            command: "am start -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER -p \(app.package)")
    }

    private func run(label: String, command: String) {
        guard connected, !busy else { return }
        busy = true
        Task {
            do {
                let response = try await adb.shell(command)
                if response.localizedCaseInsensitiveContains("Error:")
                    || response.localizedCaseInsensitiveContains("Exception") {
                    status = String(response.prefix(250))
                } else {
                    status = label
                }
            } catch {
                connected = false
                status = error.localizedDescription
            }
            busy = false
        }
    }

    func takeScreenshot() {
        guard connected, !busy else { return }
        busy = true
        status = "Получаю снимок экрана…"
        Task {
            do {
                let bytes = try await adb.screenshot()
                guard let image = UIImage(data: bytes) else { throw ADBError.missingPNG }
                screenshot = image
                showScreenshot = true
                status = "Снимок получен."
            } catch {
                connected = false
                status = error.localizedDescription
            }
            busy = false
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
