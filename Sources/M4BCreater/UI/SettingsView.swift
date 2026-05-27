import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    @State private var settings: AppSettings = .default
    @State private var davName = ""
    @State private var davURL = ""
    @State private var davUsername = ""
    @State private var davPassword = ""

    var body: some View {
        TabView {
            cacheSettings
                .tabItem {
                    Label("缓存", systemImage: "internaldrive")
                }
            webDAVSettings
                .tabItem {
                    Label("WebDAV", systemImage: "network")
                }
        }
        .padding(20)
        .onAppear {
            settings = coordinator.settings
        }
    }

    private var cacheSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("缓存策略")
                .font(.title3.weight(.semibold))
            DirectoryPickerRow(title: "缓存目录", url: settings.cacheDirectory) {
                if let directory = pickDirectory() {
                    settings.cacheDirectory = directory
                    coordinator.updateSettings(settings)
                }
            }
            HStack {
                Text("容量上限")
                Slider(
                    value: Binding(
                        get: { Double(settings.cacheLimitBytes) / 1024 / 1024 / 1024 },
                        set: {
                            settings.cacheLimitBytes = Int64($0) * 1024 * 1024 * 1024
                            coordinator.updateSettings(settings)
                        }
                    ),
                    in: 5...200,
                    step: 5
                )
                Text(settings.cacheLimitBytes.formattedBytes)
                    .frame(width: 90, alignment: .trailing)
            }
            Toggle("任务完成后自动清理源缓存", isOn: Binding(
                get: { settings.autoCleanCompletedCache },
                set: {
                    settings.autoCleanCompletedCache = $0
                    coordinator.updateSettings(settings)
                }
            ))
            Spacer()
        }
    }

    private var webDAVSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WebDAV 连接")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("名称")
                    TextField("家庭 NAS", text: $davName)
                }
                GridRow {
                    Text("地址")
                    TextField("https://example.com/dav/", text: $davURL)
                }
                GridRow {
                    Text("用户名")
                    TextField("username", text: $davUsername)
                }
                GridRow {
                    Text("密码")
                    SecureField("password", text: $davPassword)
                }
            }

            Button {
                guard let url = URL(string: davURL), !davName.isEmpty else { return }
                coordinator.upsertWebDAVCredential(name: davName, baseURL: url, username: davUsername, password: davPassword)
                davName = ""
                davURL = ""
                davUsername = ""
                davPassword = ""
            } label: {
                Label("保存连接", systemImage: "key")
            }

            List(coordinator.webDAVCredentials) { credential in
                VStack(alignment: .leading) {
                    Text(credential.name)
                    Text(credential.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 120)
        }
    }

    private func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
