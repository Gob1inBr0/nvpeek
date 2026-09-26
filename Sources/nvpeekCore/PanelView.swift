import SwiftUI
import AppKit

/// SwiftUI 原生窗口拖动手势（macOS 15+）。它完全在 SwiftUI 层实现，
/// 不经过 AppKit 会缓存"可拖动区域"的那套机制（本程序界面每几秒刷新一次，
/// AppKit 的区域缓存经常失效——这正是各种标准修法都不灵的原因）。
/// minimumDistance 保证单击按钮不受影响，拖动才触发。
struct WindowDragModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}

/// 把内容实际高度报告给窗口控制器，窗口高度跟着内容走
struct PanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public struct PanelView: View {
    @ObservedObject var store: MonitorStore
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    var onContentHeight: (CGFloat) -> Void = { _ in }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            Group {
                if store.prefs.collapsed { miniBar } else { fullContent }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PanelContentHeightKey.self,
                                           value: geo.size.height)
                })
        }
        .frame(width: 324)
        .frame(maxHeight: 580)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .onPreferenceChange(PanelContentHeightKey.self) { onContentHeight($0) }
        .modifier(WindowDragModifier())
        .contextMenu {
            Button(store.prefs.collapsed ? "展开" : "收起为迷你条") {
                store.setCollapsed(!store.prefs.collapsed)
            }
            Button("立即刷新") { store.pollAll() }
            Button("设置…") { onOpenSettings() }
            Divider()
            Button("退出") { onQuit() }
        }
    }

    // MARK: - 展开时的完整内容

    private var fullContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if store.configs.isEmpty {
                emptyCard
            }
            ForEach(store.configs) { config in
                ServerSection(
                    state: store.states[config.id] ?? ServerState(config: config),
                    onRetry: { store.poll(config) })
            }
            footer
        }
    }

    // 顶部：标题 + 小按钮，按住这里拖动窗口
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("nvpeek")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Spacer(minLength: 12)
            HeaderButton(icon: "arrow.down.right.and.arrow.up.left", help: "收起为迷你条") {
                store.setCollapsed(true)
            }
            HeaderButton(icon: "arrow.clockwise", help: "立即刷新") { store.pollAll() }
            HeaderButton(icon: "gearshape", help: "设置") { onOpenSettings() }
            HeaderButton(icon: "xmark.circle", help: "退出") { onQuit() }
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
    }

    // MARK: - 迷你小条：只显示每台机器的空闲卡数，点一下展开

    private var miniBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(store.configs) { config in
                MiniServerChip(
                    state: store.states[config.id] ?? ServerState(config: config))
            }
            Spacer(minLength: 8)
            HeaderButton(icon: "arrow.up.left.and.arrow.down.right", help: "展开") {
                store.setCollapsed(false)
            }
            HeaderButton(icon: "gearshape", help: "设置") { onOpenSettings() }
            HeaderButton(icon: "xmark.circle", help: "退出") { onQuit() }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { store.setCollapsed(false) }
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("还没有添加服务器")
                .font(.system(size: 12, weight: .medium))
            Text("点右上角齿轮添加服务器\n或直接导入 ~/.ssh/config 里的服务器")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开设置") { onOpenSettings() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        Text("每 \(store.intervalLabel) 自动刷新 · 拖动顶部标题可移动")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
    }
}

// MARK: - 迷你小条上的一台机器："别名 5/8"

struct MiniServerChip: View {
    let state: ServerState

    var body: some View {
        HStack(spacing: 3) {
            Text(prefix)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .help(tooltip)
    }

    private var prefix: String {
        let source = state.config.alias.isEmpty ? state.config.host : state.config.alias
        let p = source.prefix(4).trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? "?" : String(p)
    }

    private var value: String {
        switch state.phase {
        case .ok: return "\(state.freeGPUCount)/\(state.gpus.count)"
        case .error: return "✕"
        default: return "…"
        }
    }

    private var color: Color {
        switch state.phase {
        case .ok: return state.freeGPUCount > 0 ? .green : .primary
        case .error: return .red
        default: return .secondary
        }
    }

    private var tooltip: String {
        let name = state.config.alias.isEmpty ? state.config.summary : state.config.alias
        switch state.phase {
        case .ok: return "\(name)：空闲 \(state.freeGPUCount)/\(state.gpus.count)"
        case .error(let message): return "\(name)：\(message)"
        default: return name
        }
    }
}

private struct HeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 单台服务器卡片

struct ServerSection: View {
    let state: ServerState
    let onRetry: () -> Void
    @State private var showProcesses = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            switch state.phase {
            case .error(let message):
                errorCard(message)
            case .idle, .loading:
                if state.gpus.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("连接中…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    gpuList   // 刷新时保留上一次的数据，界面不闪
                }
            case .ok:
                gpuList
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(state.config.alias.isEmpty ? state.config.host : state.config.alias)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(state.config.summary)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if state.phase == .ok {
                Text("空闲 \(state.freeGPUCount)/\(state.gpus.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(state.freeGPUCount > 0 ? Color.green : Color.secondary)
            }
            if state.refreshing {
                ProgressView().controlSize(.mini)
            }
            Text(relativeTime)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("重试", action: onRetry)
                .buttonStyle(.link)
                .font(.system(size: 10))
                .fixedSize()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.07)))
    }

    private var gpuList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.gpus, id: \.index) { gpu in
                GPURow(gpu: gpu,
                       processes: state.processes.filter { $0.gpuIndex == gpu.index })
            }
            if !state.processes.isEmpty {
                DisclosureGroup(isExpanded: $showProcesses) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(state.processes) { p in
                            processRow(p)
                        }
                    }
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("进程（\(state.processes.count)）")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func processRow(_ p: GPUProcess) -> some View {
        HStack(spacing: 6) {
            Text("\(p.gpuIndex)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            Text(p.user)
                .lineLimit(1)
                .frame(width: 48, alignment: .leading)
            Text(p.shortName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(p.memLabel)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(p.elapsed)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10))
        .help("pid \(p.pid) · \(p.name)")
    }

    private var statusColor: Color {
        switch state.phase {
        case .ok: return .green
        case .error: return .red
        default: return .orange
        }
    }

    private var relativeTime: String {
        guard let date = state.updatedAt else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<5: return "刚刚"
        case ..<60: return "\(seconds)秒前"
        case ..<3600: return "\(seconds / 60)分前"
        default: return "\(seconds / 3600)小时前"
        }
    }
}

// MARK: - 单张 GPU

struct GPURow: View {
    let gpu: GPUInfo
    let processes: [GPUProcess]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(gpu.index)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(badgeColor))
                Text(gpu.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if gpu.temp > 0 {
                    Text("\(gpu.temp)°")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text("\(fmtMem(gpu.memUsedMiB)) / \(fmtMem(gpu.memTotalMiB))")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(gpu.memFrac > 0.9 ? .red : .primary)
            }
            HStack(spacing: 6) {
                MiniBar(fraction: Double(gpu.util) / 100, color: utilColor)
                    .frame(width: 46)
                Text("利用率 \(gpu.util)%")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                MiniBar(fraction: gpu.memFrac, color: memColor)
                    .frame(width: 46)
                Text("显存")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(0.035)))
        .help(tooltip)
    }

    private var badgeColor: Color {
        if gpu.isIdle { return .green }
        if gpu.util >= 95 || gpu.memFrac >= 0.95 { return .red }
        return .accentColor
    }
    private var utilColor: Color {
        if gpu.util >= 95 { return .red }
        if gpu.util >= 70 { return .orange }
        return .accentColor
    }
    private var memColor: Color {
        if gpu.memFrac >= 0.9 { return .red }
        if gpu.memFrac >= 0.7 { return .orange }
        return .teal
    }

    private var tooltip: String {
        if processes.isEmpty { return "空闲" }
        return processes
            .map { "#\($0.gpuIndex) \($0.user) \($0.shortName) \($0.memLabel) 已运行 \($0.elapsed)" }
            .joined(separator: "\n")
    }
}

struct MiniBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}
