import SwiftUI

extension Color {
    static let ravistyRed = Color(red: 0.96, green: 0.29, blue: 0.37)
    static let remoteCard = Color(red: 0.12, green: 0.105, blue: 0.135)
}

@MainActor
struct ContentView: View {
    @StateObject private var remote = RemoteViewModel()
    @State private var showConnection = false
    @State private var showHelp = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.23, green: 0.08, blue: 0.12), Color(red: 0.055, green: 0.055, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    connectionCard
                    dpad
                    navigationKeys
                    volume
                    favorites
                    Button { showHelp = true } label: {
                        Label("Музыка и трансляция экрана", systemImage: "questionmark.circle")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(RemotePressStyle())
                    Button(action: remote.takeScreenshot) {
                        Label("Посмотреть экран ТВ", systemImage: "rectangle.inset.filled.and.person.filled")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 17)
                            .background(Color.remoteCard, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(RemotePressStyle())
                    .disabled(!remote.connected || remote.busy)
                    Text(remote.status)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("connectionStatus")
                    if let latency = remote.lastInputLatencyMS {
                        Text("Отклик: \(latency) мс").font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .padding(.horizontal, 25).padding(.top, 26).padding(.bottom, 30)
                .frame(maxWidth: 510)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showConnection) { connectionSheet }
        .sheet(isPresented: $remote.showScreenshot) { screenshotSheet }
        .sheet(isPresented: $showHelp) { helpSheet }
        .onChange(of: scenePhase) { phase in
            if phase == .background { remote.enterBackground() }
            else if phase == .active { remote.enterForeground() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ВАШ ЛИЧНЫЙ ПУЛЬТ").font(.system(size: 9, weight: .bold)).tracking(3.2).foregroundStyle(Color.ravistyRed)
                Text("РАВИСТЫ / TV").font(.system(size: 25, weight: .bold, design: .rounded)).tracking(0.6)
            }
            Spacer()
            Image(systemName: "star.fill").font(.system(size: 21)).foregroundStyle(Color.ravistyRed)
                .frame(width: 48, height: 48).background(Color.ravistyRed.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
        }
    }

    private var connectionCard: some View {
        Button { showConnection = true } label: {
            HStack(spacing: 13) {
                Circle().fill(remote.connected ? Color.green : Color.ravistyRed).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(remote.device).font(.system(size: 14, weight: .semibold))
                    Text(remote.connected ? "Подключён · \(remote.host)" : "\(remote.host) · нажмите для подключения")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 8)
                if remote.busy { ProgressView().tint(.ravistyRed) }
                else { Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.4)) }
            }
            .padding(17).background(Color.remoteCard, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(RemotePressStyle())
    }

    private var dpad: some View {
        ZStack {
            Circle().fill(Color.remoteCard)
                .overlay(Circle().strokeBorder(.white.opacity(0.07), lineWidth: 1))
            VStack(spacing: 0) {
                keyButton("chevron.up", code: 19, label: "Вверх").frame(width: 94, height: 78)
                HStack(spacing: 0) {
                    keyButton("chevron.left", code: 21, label: "Влево").frame(width: 78, height: 94)
                    Button { remote.key(23, label: "ОК") } label: {
                        Text("OK").font(.system(size: 19, weight: .bold))
                            .frame(width: 86, height: 86)
                            .background(LinearGradient(colors: [.ravistyRed, Color(red: 0.64, green: 0.16, blue: 0.25)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    }
                    .buttonStyle(RemotePressStyle()).accessibilityLabel("ОК")
                    keyButton("chevron.right", code: 22, label: "Вправо").frame(width: 78, height: 94)
                }
                keyButton("chevron.down", code: 20, label: "Вниз").frame(width: 94, height: 78)
            }
        }
        .frame(width: 260, height: 260)
        .disabled(!remote.connected)
        .opacity(remote.connected ? 1 : 0.55)
    }

    private func keyButton(_ symbol: String, code: Int, label: String) -> some View {
        Button { remote.key(code, label: label) } label: {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemotePressStyle()).accessibilityLabel(label)
    }

    private var navigationKeys: some View {
        HStack(spacing: 16) {
            pill("arrow.uturn.backward", label: "Назад") { remote.key(4, label: "Назад") }
            pill("house.fill", label: "Домой") { remote.key(3, label: "Домой") }
            pill("speaker.slash.fill", label: "Без звука") { remote.key(164, label: "Переключение звука") }
        }
        .disabled(!remote.connected)
    }

    private func pill(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }.frame(maxWidth: .infinity).frame(height: 76)
                .background(Color.remoteCard, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(RemotePressStyle()).accessibilityLabel(label)
    }

    private var volume: some View {
        HStack {
            Button { remote.key(25, label: "Тише") } label: {
                Image(systemName: "minus").font(.system(size: 20, weight: .medium)).frame(width: 64, height: 53)
            }.accessibilityLabel("Уменьшить громкость")
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 13))
                Text("ГРОМКОСТЬ").font(.system(size: 10, weight: .semibold)).tracking(2)
            }.foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button { remote.key(24, label: "Громче") } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .medium)).frame(width: 64, height: 53)
            }.accessibilityLabel("Увеличить громкость")
        }
        .background(Color.remoteCard, in: Capsule()).buttonStyle(RemotePressStyle())
        .disabled(!remote.connected)
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("БЫСТРЫЙ ЗАПУСК").font(.system(size: 10, weight: .bold)).tracking(2.4).foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                ForEach(RemoteApp.favorites) { app in
                    Button { remote.launch(app) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: app.symbol).font(.system(size: 18)).foregroundStyle(app.tint).frame(width: 24)
                            Text(app.name).font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 14).frame(height: 56)
                            .background(Color.remoteCard, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(RemotePressStyle())
                }
            }.disabled(!remote.connected || remote.busy)
        }
    }

    private var connectionSheet: some View {
        NavigationStack {
            Form {
                Section("Телевизор в локальной сети") {
                    TextField("IP-адрес", text: $remote.host).keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Порт ADB", text: $remote.portText).keyboardType(.numberPad)
                }
                Section {
                    Text("Включите отладку на телевизоре. При первом подключении подтвердите доступ для этого iPhone на экране ТВ.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(remote.status).font(.footnote)
                    if remote.busy {
                        ProgressView("Выполняется запрос…")
                        if !remote.connected {
                            Button("Отменить подключение", role: .destructive) { remote.disconnect() }
                        }
                    }
                    Button(remote.connected ? "Подключить заново" : "Подключить") { remote.connect() }.disabled(remote.busy)
                    if remote.connected {
                        Button("Отключить", role: .destructive) { remote.disconnect() }.disabled(remote.busy)
                    }
                }
                Section {
                    Text("Пульт общается с ТВ напрямую по ADB. Ключ доступа хранится в Keychain этого iPhone. Снимки экрана запрашиваются только по нажатию кнопки и не отправляются в облако.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Подключение")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showConnection = false } } }
        }
        .tint(.ravistyRed).preferredColorScheme(.dark)
    }

    private var screenshotSheet: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = remote.screenshot {
                    Image(uiImage: image).resizable().scaledToFit().padding(8)
                }
            }
            .navigationTitle("Экран телевизора").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { remote.showScreenshot = false } }
            }
        }.tint(.ravistyRed).preferredColorScheme(.dark)
    }

    private var helpSheet: some View {
        NavigationStack {
            Form {
                Section("Повтор экрана iPhone") {
                    Text("Откройте «Экран телефона (AirScreen)» на телевизоре. На iPhone откройте Пункт управления → Повтор экрана и выберите телевизор. Оба устройства должны быть в одной сети Wi-Fi.")
                }
                Section("Google Cast") {
                    Text("Откройте «Экран телефона (AirScreen)» на телевизоре, затем нажмите значок трансляции в приложении с поддержкой Google Cast и выберите телевизор.")
                }
                Section("Яндекс Музыка") {
                    Text("Откройте Кинопоиск на телевизоре и выберите «Музыка» в левом меню.")
                }
            }
            .navigationTitle("Музыка и экран")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { showHelp = false } }
            }
        }
        .tint(.ravistyRed).preferredColorScheme(.dark)
    }
}

struct RemotePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
