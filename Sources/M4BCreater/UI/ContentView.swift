import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    @State private var showingNewJob = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showingNewJob: $showingNewJob)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            JobListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 390)
        } detail: {
            if let job = coordinator.selectedJob {
                JobDetailView(job: job)
            } else {
                EmptyStateView()
            }
        }
        .sheet(isPresented: $showingNewJob) {
            NewJobView()
                .environmentObject(coordinator)
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator
    @Binding var showingNewJob: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("M4B Creater")
                    .font(.system(size: 24, weight: .semibold))
                Text("有声书转换工作台")
                    .foregroundStyle(.secondary)
            }

            Button {
                showingNewJob = true
            } label: {
                Label("新建任务", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            VStack(alignment: .leading, spacing: 10) {
                SidebarMetric(title: "任务", value: "\(coordinator.jobs.count)", icon: "list.bullet.rectangle")
                SidebarMetric(title: "运行中", value: "\(coordinator.jobs.filter { $0.state == .running }.count)", icon: "play.circle")
                SidebarMetric(title: "缓存", value: coordinator.settings.cacheLimitBytes.formattedBytes, icon: "internaldrive")
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Label(coordinator.ffmpegStatus, systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("WebDAV 为可选远程目录，本地输入输出始终可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}

private struct SidebarMetric: View {
    var title: String
    var value: String
    var icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

private struct JobListView: View {
    @EnvironmentObject private var coordinator: ConversionCoordinator

    var body: some View {
        List(selection: $coordinator.selectedJobID) {
            ForEach(coordinator.jobs) { job in
                JobRowView(job: job)
                    .tag(job.id)
            }
        }
        .overlay {
            if coordinator.jobs.isEmpty {
                ContentUnavailableView("暂无任务", systemImage: "tray", description: Text("创建一个本地或 WebDAV 转换任务。"))
            }
        }
        .navigationTitle("任务队列")
    }
}

private struct JobRowView: View {
    var job: ConversionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            ProgressView(value: job.progress.total)
                .controlSize(.small)
            HStack {
                Text(job.stage.label)
                Spacer()
                Text(job.progress.total, format: .percent.precision(.fractionLength(0)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch job.state {
        case .running: .accentColor
        case .failed: .red
        case .completed: .green
        case .paused: .orange
        default: .secondary
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "选择一个任务",
            systemImage: "waveform",
            description: Text("任务详情、元数据、进度和日志会显示在这里。")
        )
    }
}
