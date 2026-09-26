import Foundation

/// ~/.ssh/config 里的一个 Host 条目
public struct SSHHostEntry: Identifiable, Hashable {
    public var id: String { alias }
    public let alias: String
    public let hostname: String?   // 配置里没写 HostName 时为空，表示用别名本身当地址
    public let user: String?
    public let port: Int?

    /// 列表里展示的一行摘要
    public var detail: String {
        var parts: [String] = []
        let target = hostname ?? alias
        parts.append((user.map { "\($0)@" } ?? "") + target)
        if let port, port != 22 { parts.append("端口 \(port)") }
        if hostname == nil { parts.append("别名直连") }
        return parts.joined(separator: " · ")
    }
}

/// 解析 ~/.ssh/config，取出所有 Host 条目。
/// 规则和 ssh 保持一致的关键两点：
/// 1) 同一个参数先出现的生效（先到先得）；
/// 2) Include 指令在原位置展开，相对路径相对于 ~/.ssh。
/// 带 * ? 通配符或 ! 取反的主机名不列出（它们是模式，不是具体某台机器）。
public enum SSHConfigParser {

    /// 读默认位置的 ~/.ssh/config
    public static func parseDefaultConfig() -> [SSHHostEntry] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        return parse(fileURLs: [url])
    }

    /// 从给定的配置文件开始解析（测试用）
    public static func parse(fileURLs: [URL]) -> [SSHHostEntry] {
        var order: [String] = []                 // 别名首次出现的顺序
        var hostnames: [String: String] = [:]
        var users: [String: String] = [:]
        var ports: [String: Int] = [:]
        var currentAliases: [String] = []
        var visited: Set<String> = []            // 防止 Include 循环

        func readFile(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !visited.contains(path) else { return }
            visited.insert(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }

            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let keyword = tokens.first?.lowercased() else { continue }
                let args = Array(tokens.dropFirst())

                switch keyword {
                case "host":
                    currentAliases = args
                        .flatMap { $0.split(separator: ",").map(String.init) }
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                    for alias in currentAliases where !order.contains(alias) {
                        order.append(alias)
                    }
                case "hostname":
                    let value = args.joined(separator: " ")
                    guard !value.isEmpty else { continue }
                    for a in currentAliases where hostnames[a] == nil { hostnames[a] = value }
                case "user":
                    let value = args.joined(separator: " ")
                    guard !value.isEmpty else { continue }
                    for a in currentAliases where users[a] == nil { users[a] = value }
                case "port":
                    guard let value = args.first.flatMap({ Int($0) }) else { continue }
                    for a in currentAliases where ports[a] == nil { ports[a] = value }
                case "include":
                    for arg in args { readFile(resolveInclude(arg)) }
                default:
                    break
                }
            }
        }

        for url in fileURLs { readFile(url) }
        return order.map {
            SSHHostEntry(alias: $0, hostname: hostnames[$0], user: users[$0], port: ports[$0])
        }
    }

    /// Include 的路径：~ 开头换成用户主目录，相对路径相对 ~/.ssh
    static func resolveInclude(_ arg: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if arg == "~" || arg.hasPrefix("~/") {
            return home.appendingPathComponent(String(arg.dropFirst(2)))
        }
        if arg.hasPrefix("/") {
            return URL(fileURLWithPath: arg)
        }
        return home.appendingPathComponent(".ssh").appendingPathComponent(arg)
    }
}
