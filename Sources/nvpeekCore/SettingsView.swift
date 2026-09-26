import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var store: MonitorStore
    @State private var editing: ServerConfig?
    @State private var addingNew = false
    @State private var loginError: String?
    // ~/.ssh/config 里读到的主机
    @State private var sshHosts: [SSHHostEntry] = []
    @State private var selectedAliases: Set<String> = []
    @State private var sshLoaded = false
    // 快捷键录制状态
    @State private var recordingHotkey = false

    public var body: some View {
        Form {
            Section("服务器") {
                if store.configs.isEmpty {
                    Text("还没有服务器，从下面导入或点“添加服务器”")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.configs) { config in
                    ServerRow(
                        config: config,
                        onEdit: { editing = config },
                        onDelete: { store.removeServer(config.id) })
                }
                Button {
                    addingNew = true
                } label: {
                    Label("手动添加服务器", systemImage: "plus")
                }
            }

            sshImportSection

            Section("显示") {
                Picker("显示方式", selection: displayModeBinding) {
                    Text("钉在桌面（被窗口遮挡）").tag(DisplayMode.desktop)
                    Text("悬浮在所有窗口前").tag(DisplayMode.floating)
                }
                Toggle("快捷键显示 / 隐藏", isOn: hotkeyEnabledBinding)
                HStack {
                    Text("快捷键：\(store.prefs.hotkeyLabel)")
                    Spacer()
                    if recordingHotkey {
                        HotKeyRecorderView(
                            onCapture: { keyCode, modifiers, label in
                                store.setHotKey(keyCode: keyCode, modifiers: modifiers, label: label)
                                recordingHotkey = false
                            },
                            onCancel: { recordingHotkey = false })
                            .frame(width: 120, height: 22)
                        Button("取消") { recordingHotkey = false }
                    } else {
                        Button("修改") { recordingHotkey = true }
                    }
                }
                Text("迷你模式：点小组件标题栏的收缩按钮，缩成只显示各机器空闲卡数的小条，点小条展开；状态会记住。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("刷新") {
                Picker("自动刷新间隔", selection: intervalBinding) {
                    ForEach([2.0, 5.0, 10.0, 30.0, 60.0], id: \.self) { value in
                        Text("\(Int(value)) 秒").tag(value)
                    }
                }
                Text("间隔太短会增加服务器负载，一般 5 秒比较合适。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("其他") {
                Toggle("登录 macOS 后自动启动", isOn: loginBinding)
                if let loginError {
                    Text(loginError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                HStack {
                    Text("演示模式")
                    Spacer()
                    Text(store.demo ? "开启（显示假数据）" : "关闭")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onAppear {
            guard !sshLoaded else { return }
            sshHosts = SSHConfigParser.parseDefaultConfig()
            selectedAliases = Set(sshHosts.map(\.alias))
            sshLoaded = true
        }
        .sheet(item: $editing) { config in
            ServerEditSheet(
                config: config,
                onSave: { store.updateServer($0) },
                onDelete: { store.removeServer(config.id) })
        }
        .sheet(isPresented: $addingNew) {
            ServerEditSheet(
                config: nil,
                onSave: { store.addServer($0) },
                onDelete: nil)
        }
    }

    // MARK: - 从 ~/.ssh/config 导入

    private var pendingSSHHosts: [SSHHostEntry] {
        sshHosts.filter { entry in
            !store.configs.contains { config in
                config.user.trimmingCharacters(in: .whitespaces).isEmpty
                    ? config.host == entry.alias
                    : config.host == (entry.hostname ?? entry.alias)
                        && config.user == (entry.user ?? "")
            }
        }
    }

    @ViewBuilder
    private var sshImportSection: some View {
        Section("~/.ssh/config 里的服务器") {
            if !sshLoaded {
                Text("读取中…").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if sshHosts.isEmpty {
                Text("没找到 ~/.ssh/config，或里面没有 Host 条目")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if pendingSSHHosts.isEmpty {
                Text("config 里的服务器都已添加 ✓")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pendingSSHHosts) { entry in
                    Toggle(isOn: selectBinding(entry.alias)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.alias)
                                .font(.system(size: 12, weight: .medium))
                            Text(entry.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                HStack {
                    let count = pendingSSHHosts.filter { selectedAliases.contains($0.alias) }.count
                    Button("导入选中（\(count)）") {
                        importSelected(pendingSSHHosts)
                    }
                    .disabled(count == 0)
                    Spacer()
                    Button("全选") {
                        selectedAliases = Set(pendingSSHHosts.map(\.alias))
                    }
                }
                Text("导入后按别名连接：配置里的地址、端口、密钥、跳板机都会自动生效，不会每台都去试连。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func selectBinding(_ alias: String) -> Binding<Bool> {
        Binding(
            get: { selectedAliases.contains(alias) },
            set: { on in
                if on { selectedAliases.insert(alias) } else { selectedAliases.remove(alias) }
            })
    }

    private func importSelected(_ pending: [SSHHostEntry]) {
        for entry in pending where selectedAliases.contains(entry.alias) {
            store.addServer(ServerConfig(alias: entry.alias, host: entry.alias, user: "", port: 22))
        }
        selectedAliases.subtract(pending.map(\.alias))
    }

    private var intervalBinding: Binding<TimeInterval> {
        Binding(
            get: { store.interval },
            set: { store.setInterval($0) })
    }

    private var displayModeBinding: Binding<DisplayMode> {
        Binding(
            get: { store.prefs.mode },
            set: { store.setDisplayMode($0) })
    }

    private var hotkeyEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.prefs.hotkeyEnabled },
            set: { store.setHotkeyEnabled($0) })
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { LoginItem.isEnabled },
            set: { on in
                do {
                    try LoginItem.setEnabled(on)
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                }
            })
    }
}

private struct ServerRow: View {
    let config: ServerConfig
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(config.alias.isEmpty ? "（未命名）" : config.alias)
                    .font(.system(size: 12, weight: .medium))
                Text(config.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("编辑", action: onEdit)
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除这台服务器")
        }
        .padding(.vertical, 2)
    }
}

/// 添加 / 编辑一台服务器的表单（在弹窗里）
struct ServerEditSheet: View {
    let config: ServerConfig?          // nil 表示新增
    let onSave: (ServerConfig) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var alias: String
    @State private var user: String
    @State private var host: String
    @State private var port: String

    init(config: ServerConfig?, onSave: @escaping (ServerConfig) -> Void, onDelete: (() -> Void)?) {
        self.config = config
        self.onSave = onSave
        self.onDelete = onDelete
        _alias = State(initialValue: config?.alias ?? "")
        _user = State(initialValue: config?.user ?? "")
        _host = State(initialValue: config?.host ?? "")
        _port = State(initialValue: config.map { String($0.port) } ?? "22")
    }

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(config == nil ? "添加服务器" : "编辑服务器")
                .font(.system(size: 13, weight: .semibold))

            Form {
                TextField("别名（显示在小组件上，可留空）", text: $alias)
                TextField("用户名（留空 = 按 ~/.ssh/config 别名连接）", text: $user)
                TextField("主机（IP、域名，或 ssh 配置里的别名）", text: $host)
                TextField("端口（默认 22，别名连接时忽略）", text: $port)
            }
            .formStyle(.grouped)

            Text("两种填法：\n1. 直接填 用户名@主机，例如 root@192.168.1.10\n2. 用户名留空，主机填 ~/.ssh/config 里的 Host 别名，地址、端口、密钥、跳板机都按配置来")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack {
                if let onDelete {
                    Button("删除这台服务器", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    var updated = config ?? ServerConfig()
                    updated.alias = alias.trimmingCharacters(in: .whitespaces)
                    updated.user = user.trimmingCharacters(in: .whitespaces)
                    updated.host = host.trimmingCharacters(in: .whitespaces)
                    updated.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? 22
                    onSave(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 420, height: 300)
    }
}
