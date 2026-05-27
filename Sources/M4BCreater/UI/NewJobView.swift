import AppKit
import SwiftUI

struct NewJobView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var webDAVInput = ""
    @State private var webDAVOutput = ""
    @State private var useWebDAVInput = false
    @State private var useWebDAVOutput = false
    @State private var selectedCredentialID: UUID?

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
                TextField("https://example.com/dav/book/", text: $webDAVInput)
                    .textFieldStyle(.roundedBorder)
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
                TextField("https://example.com/dav/output/", text: $webDAVOutput)
                    .textFieldStyle(.roundedBorder)
            } else {
                DirectoryPickerRow(title: "输出目录", url: outputURL) {
                    outputURL = Self.pickDirectory()
                }
            }

            if useWebDAVInput || useWebDAVOutput {
                Picker("WebDAV 凭据", selection: $selectedCredentialID) {
                    Text("无").tag(UUID?.none)
                    ForEach(coordinator.webDAVCredentials) { credential in
                        Text(credential.name).tag(Optional(credential.id))
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
        .frame(width: 620, height: 430)
    }

    private var isValid: Bool {
        let validInput = useWebDAVInput ? URL(string: webDAVInput) != nil : inputURL != nil
        let validOutput = useWebDAVOutput ? URL(string: webDAVOutput) != nil : outputURL != nil
        return validInput && validOutput
    }

    private func create() {
        if !useWebDAVInput, !useWebDAVOutput, let inputURL, let outputURL {
            coordinator.createLocalJob(inputURL: inputURL, outputURL: outputURL)
            return
        }
        guard let input = useWebDAVInput ? URL(string: webDAVInput) : inputURL else { return }
        guard let output = useWebDAVOutput ? URL(string: webDAVOutput) : outputURL else { return }
        coordinator.createWebDAVJob(inputURL: input, outputURL: output, credentialID: selectedCredentialID)
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
