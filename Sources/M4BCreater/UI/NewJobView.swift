import AppKit
import SwiftUI

struct NewJobView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var webDAVInputLocation: StorageLocation?
    @State private var webDAVOutputLocation: StorageLocation?
    @State private var useWebDAVInput = false
    @State private var useWebDAVOutput = false
    @State private var browserPurpose: WebDAVBrowserPurpose?
    @State private var encodingSettings: EncodingSettings = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("新建转换任务")
                .font(.title2.weight(.semibold))

            Picker("输入类型", selection: $useWebDAVInput) {
                Text("本地目录").tag(false)
                Text("WebDAV 目录").tag(true)
            }
            .pickerStyle(.segmented)

            if useWebDAVInput {
                WebDAVSelectionRow(title: "输入目录", location: webDAVInputLocation) {
                    browserPurpose = .input
                }
            } else {
                DirectoryPickerRow(title: "输入目录", url: inputURL) {
                    inputURL = Self.pickDirectory()
                }
            }

            Picker("输出类型", selection: $useWebDAVOutput) {
                Text("本地目录").tag(false)
                Text("WebDAV 目录").tag(true)
            }
            .pickerStyle(.segmented)

            if useWebDAVOutput {
                WebDAVSelectionRow(title: "输出目录", location: webDAVOutputLocation) {
                    browserPurpose = .output
                }
            } else {
                DirectoryPickerRow(title: "输出目录", url: outputURL) {
                    outputURL = Self.pickDirectory()
                }
            }

            HStack(spacing: 16) {
                Picker("编码", selection: $encodingSettings.codec) {
                    ForEach(AudioCodec.allCases) { codec in
                        Text(codec.label).tag(codec)
                    }
                }
                Picker("码率", selection: $encodingSettings.bitrateKbps) {
                    ForEach(EncodingSettings.availableBitrates, id: \.self) { bitrate in
                        Text("\(bitrate) kbps").tag(bitrate)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("创建") {
                    create()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 680, height: 430)
        .sheet(item: $browserPurpose) { purpose in
            WebDAVBrowserView(title: purpose.title) { location in
                switch purpose {
                case .input:
                    webDAVInputLocation = location
                case .output:
                    webDAVOutputLocation = location
                }
            }
            .environmentObject(coordinator)
        }
    }

    private var isValid: Bool {
        let validInput = useWebDAVInput ? webDAVInputLocation != nil : inputURL != nil
        let validOutput = useWebDAVOutput ? webDAVOutputLocation != nil : outputURL != nil
        return validInput && validOutput
    }

    private func create() {
        guard let input = selectedInputLocation, let output = selectedOutputLocation else { return }
        if input.kind == .local, output.kind == .local {
            coordinator.createLocalJob(inputURL: input.url, outputURL: output.url, encodingSettings: encodingSettings)
        } else {
            coordinator.createJob(input: input, output: output, encodingSettings: encodingSettings)
        }
    }

    private var selectedInputLocation: StorageLocation? {
        if useWebDAVInput {
            webDAVInputLocation
        } else {
            inputURL.map { StorageLocation(kind: .local, displayName: $0.lastPathComponent, url: $0) }
        }
    }

    private var selectedOutputLocation: StorageLocation? {
        if useWebDAVOutput {
            webDAVOutputLocation
        } else {
            outputURL.map { StorageLocation(kind: .local, displayName: $0.lastPathComponent, url: $0) }
        }
    }

    private static func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private enum WebDAVBrowserPurpose: String, Identifiable {
    case input
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input: "选择 WebDAV 输入目录"
        case .output: "选择 WebDAV 输出目录"
        }
    }
}

private struct WebDAVSelectionRow: View {
    var title: String
    var location: StorageLocation?
    var action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(location?.displayPath ?? "未选择 WebDAV 目录")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                action()
            } label: {
                Label("浏览", systemImage: "network")
            }
        }
    }
}

private struct WebDAVBrowserView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    @Environment(\.dismiss) private var dismiss
    var title: String
    var onSelect: (StorageLocation) -> Void

    @State private var selectedCredentialID: UUID?
    @State private var currentURL: URL?
    @State private var selectedItem: StorageItem?
    @State private var items: [StorageItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingAddServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    showingAddServer = true
                } label: {
                    Label("添加服务器", systemImage: "plus")
                }
            }

            HStack {
                Picker("服务器", selection: $selectedCredentialID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(coordinator.webDAVCredentials) { credential in
                        Text(credential.name).tag(Optional(credential.id))
                    }
                }
                .frame(maxWidth: 320)

                Button {
                    loadCurrentDirectory()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(selectedCredentialID == nil || isLoading)
            }

            HStack(spacing: 10) {
                Button {
                    goUp()
                } label: {
                    Label("上一级", systemImage: "chevron.up")
                }
                .disabled(currentURL == nil || isLoading)

                Text(currentURL?.absoluteString ?? "选择或添加一个 WebDAV 服务器")
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            List(items, selection: Binding(
                get: { selectedItem?.id },
                set: { url in selectedItem = items.first { $0.id == url } }
            )) { item in
                let iconName = item.isDirectory ? "folder" : "doc"
                let iconColor: Color = item.isDirectory ? .accentColor : .secondary
                HStack {
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name.isEmpty ? item.url.lastPathComponent : item.name)
                        Text(item.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if !item.isDirectory {
                        Text(item.size.formattedBytes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedItem = item
                }
                .onTapGesture(count: 2) {
                    open(item)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("加载目录...")
                } else if selectedCredentialID == nil {
                    ContentUnavailableView("没有选择服务器", systemImage: "network", description: Text("先添加或选择一个 WebDAV 服务器。"))
                } else if items.isEmpty {
                    ContentUnavailableView("目录为空", systemImage: "folder", description: Text("可以选择当前目录。"))
                }
            }

            HStack {
                Button("取消") {
                    dismiss()
                }
                Spacer()
                Button {
                    if let item = selectedItem, item.isDirectory {
                        open(item)
                    }
                } label: {
                    Label("打开", systemImage: "folder")
                }
                .disabled(selectedItem?.isDirectory != true || isLoading)

                Button("选择当前目录") {
                    selectCurrentDirectory()
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentURL == nil || selectedCredentialID == nil)
            }
        }
        .padding(24)
        .frame(width: 820, height: 620)
        .onAppear {
            if selectedCredentialID == nil {
                selectedCredentialID = coordinator.webDAVCredentials.first?.id
            }
            syncCurrentURLWithSelectedServer()
            loadCurrentDirectory()
        }
        .onChange(of: selectedCredentialID) {
            syncCurrentURLWithSelectedServer()
            loadCurrentDirectory()
        }
        .sheet(isPresented: $showingAddServer) {
            AddWebDAVServerView { credentialID in
                selectedCredentialID = credentialID
                syncCurrentURLWithSelectedServer()
                loadCurrentDirectory()
            }
            .environmentObject(coordinator)
        }
    }

    private func syncCurrentURLWithSelectedServer() {
        guard let selectedCredentialID else {
            currentURL = nil
            items = []
            return
        }
        currentURL = coordinator.webDAVCredentials.first { $0.id == selectedCredentialID }?.baseURL
        selectedItem = nil
    }

    private func loadCurrentDirectory() {
        guard let selectedCredentialID, let currentURL else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                items = try await coordinator.listWebDAVDirectory(credentialID: selectedCredentialID, url: currentURL)
                selectedItem = nil
            } catch {
                items = []
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
        }
    }

    private func open(_ item: StorageItem) {
        guard item.isDirectory else { return }
        currentURL = ConversionCoordinator.normalizedDirectoryURL(item.url)
        selectedItem = nil
        loadCurrentDirectory()
    }

    private func goUp() {
        guard let currentURL else { return }
        let parent = currentURL.deletingLastPathComponent()
        self.currentURL = ConversionCoordinator.normalizedDirectoryURL(parent)
        selectedItem = nil
        loadCurrentDirectory()
    }

    private func selectCurrentDirectory() {
        guard let selectedCredentialID, let currentURL else { return }
        let credentialName = coordinator.webDAVCredentials.first { $0.id == selectedCredentialID }?.name ?? "WebDAV"
        let displayName = currentURL.lastPathComponent.isEmpty ? credentialName : currentURL.lastPathComponent
        onSelect(StorageLocation(
            kind: .webDAV,
            displayName: displayName,
            url: ConversionCoordinator.normalizedDirectoryURL(currentURL),
            credentialID: selectedCredentialID
        ))
        dismiss()
    }
}

private struct AddWebDAVServerView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    @Environment(\.dismiss) private var dismiss
    var onSave: (UUID) -> Void

    var body: some View {
        WebDAVServerFormView {
            dismiss()
        } onSave: { name, baseURL, username, password in
            let id = coordinator.upsertWebDAVCredential(
                name: name,
                baseURL: baseURL,
                username: username,
                password: password
            )
            onSave(id)
            dismiss()
        }
    }
}

struct DirectoryPickerRow: View {
    var title: String
    var url: URL?
    var action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url?.path(percentEncoded: false) ?? "未选择")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                action()
            } label: {
                Label("选择", systemImage: "folder")
            }
        }
    }
}
