import Foundation

public enum ParseError: Error, Equatable {
    /// 服务器端 nvidia-smi 报的错（取自 stderr），或读不到 GPU 信息的提示
    case remote(String)
    /// 输出格式完全对不上
    case badOutput(String)
}

/// 解析一次 SSH 拉回来的 nvidia-smi 原始输出
public enum Parser {
    static let gpuMarker = "@@GPU@@"
    static let procMarker = "@@PROC@@"
    static let psMarker = "@@PS@@"

    public static func parse(stdout: String, stderr: String) throws -> (gpus: [GPUInfo], processes: [GPUProcess]) {
        // 输出按标记分成三段：显卡列表、计算进程列表、进程所属用户和运行时长
        var sections: [String: [String]] = [:]
        var current = ""
        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == gpuMarker || trimmed == procMarker || trimmed == psMarker {
                current = trimmed
                sections[current] = []
                continue
            }
            if !trimmed.isEmpty { sections[current, default: []].append(line) }
        }

        var gpus: [GPUInfo] = []
        for line in sections[gpuMarker] ?? [] {
            let f = csvFields(line)
            guard f.count >= 7, let idx = Int(f[0]) else { continue }
            gpus.append(GPUInfo(index: idx,
                                name: f[1],
                                uuid: f[2],
                                memUsedMiB: Int(f[3]) ?? 0,
                                memTotalMiB: Int(f[4]) ?? 0,
                                util: Int(f[5]) ?? 0,
                                temp: Int(f[6]) ?? 0))
        }
        if gpus.isEmpty {
            let msg = firstLine(of: stderr)
            throw ParseError.remote(msg.isEmpty
                ? "没有读到 GPU 信息：服务器上可能没装 nvidia-smi，或没有 NVIDIA 显卡"
                : msg)
        }

        var uuidToIndex: [String: Int] = [:]
        for g in gpus where !g.uuid.isEmpty { uuidToIndex[g.uuid] = g.index }

        // ps 输出：pid  user  etime
        var psInfo: [Int: (user: String, etime: String)] = [:]
        for line in sections[psMarker] ?? [] {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 3, let pid = Int(parts[0]) {
                psInfo[pid] = (parts[1], parts[2])
            }
        }

        var procs: [GPUProcess] = []
        for line in sections[procMarker] ?? [] {
            let f = csvFields(line)
            guard f.count >= 4, let pid = Int(f[1]) else { continue }
            let ps = psInfo[pid]
            procs.append(GPUProcess(pid: pid,
                                    user: ps?.user ?? "?",
                                    name: f[2],
                                    memMiB: Int(f[3]),   // 读不到时是 "[N/A]" 之类，Int 解析失败正好是 nil
                                    gpuIndex: uuidToIndex[f[0]] ?? -1,
                                    elapsed: ps?.etime ?? ""))
        }
        procs.sort {
            if $0.gpuIndex != $1.gpuIndex { return $0.gpuIndex < $1.gpuIndex }
            return ($0.memMiB ?? 0) > ($1.memMiB ?? 0)
        }
        return (gpus, procs)
    }

    static func firstLine(of text: String) -> String {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(160)) }
        }
        return ""
    }

    /// 解析一行 nvidia-smi 的 CSV 输出，处理带引号的字段（命令名里可能有逗号）
    public static func csvFields(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if inQuotes {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        cur.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    cur.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    out.append(cur.trimmingCharacters(in: .whitespaces))
                    cur = ""
                } else {
                    cur.append(c)
                }
            }
            i = line.index(after: i)
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }
}
