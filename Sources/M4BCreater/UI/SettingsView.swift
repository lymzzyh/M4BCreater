import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    @State private var settings: AppSettings = .default
    @State private var selectedCredentialID: UUID?
    @State private var showingAddServer = false

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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("WebDAV 服务器")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    showingAddServer = true
                } label: {
                    Label("添加服务器", systemImage: "plus")
                }
            }

            HStack(spacing: 16) {
                List(selection: $selectedCredentialID) {
                    ForEach(coordinator.webDAVCredentials) { credential in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credential.name)
                                Text(credential.baseURL.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                        .tag(Optional(credential.id))
                    }
                }
                .frame(minWidth: 260, minHeight: 240)
                .overlay {
                    if coordinator.webDAVCredentials.isEmpty {
                        ContentUnavailableView("暂无服务器", systemImage: "network", description: Text("添加 WebDAV 服务器后可在新建任务中浏览选择目录。"))
                    }
                }

                Divider()

                WebDAVServerDetailView(credential: selectedCredential)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .sheet(isPresented: $showingAddServer) {
            WebDAVServerFormView {
                showingAddServer = false
            } onSave: { name, baseURL, username, password in
                let id = coordinator.upsertWebDAVCredential(
                    name: name,
                    baseURL: baseURL,
                    username: username,
                    password: password
                )
                selectedCredentialID = id
                showingAddServer = false
            }
        }
        .onAppear {
            if selectedCredentialID == nil {
                selectedCredentialID = coordinator.webDAVCredentials.first?.id
            }
        }
    }

    private var selectedCredential: WebDAVCredential? {
        guard let selectedCredentialID else { return nil }
        return coordinator.webDAVCredentials.first { $0.id == selectedCredentialID }
    }

    private struct WebDAVServerDetailView: View {
        var credential: WebDAVCredential?

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                if let credential {
                    Label("服务器详情", systemImage: "server.rack")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        DetailRow(title: "名称", value: credential.name)
                        DetailRow(title: "地址", value: credential.baseURL.absoluteString)
                        DetailRow(title: "用户名", value: credential.username.isEmpty ? "未设置" : credential.username)
                        DetailRow(title: "密码", value: "已保存在钥匙串引用中")
                    }

                    Text("新建任务时选择 WebDAV 目录，会使用这里保存的服务器和鉴权信息浏览远程目录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ContentUnavailableView("选择一个服务器", systemImage: "server.rack", description: Text("服务器详情会显示在这里。"))
                }
            }
            .padding(4)
        }
    }

    private struct DetailRow: View {
        var title: String
        var value: String

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
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
