import SwiftUI

struct WebDAVServerFormView: View {
    @State private var name = ""
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""

    var title: String = "添加 WebDAV 服务器"
    var onCancel: () -> Void
    var onSave: (_ name: String, _ baseURL: URL, _ username: String, _ password: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("名称")
                    TextField("家庭 NAS", text: $name)
                }
                GridRow {
                    Text("地址")
                    TextField("https://example.com/dav/", text: $baseURL)
                }
                GridRow {
                    Text("用户名")
                    TextField("username", text: $username)
                }
                GridRow {
                    Text("密码")
                    SecureField("password", text: $password)
                }
            }
            .textFieldStyle(.roundedBorder)

            Spacer()

            HStack {
                Button("取消") {
                    onCancel()
                }
                Spacer()
                Button("保存") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 540, height: 300)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            URL(string: baseURL) != nil
    }

    private func save() {
        guard let url = URL(string: baseURL) else { return }
        onSave(
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            url,
            username,
            password
        )
    }
}
