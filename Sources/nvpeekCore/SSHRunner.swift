import Foundation

public struct SSHResult {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public enum SSHError: Error {
    case timeout
    case launchFailed(String)
}

/// 在远端一次性执行的命令。三段输出用标记分隔，一次 SSH 往返拿到全部数据：
/// 1) 每张卡的状态  2) 每张卡上的计算进程  3) 这些进程属于谁、跑了多久
public enum GPURemote {
    static let command = """
    echo @@GPU@@; nvidia-smi --query-gpu=index,name,uuid,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader,nounits; echo @@PROC@@; nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits; echo @@PS@@; P=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits | sort -un | tr '\\n' ',' | sed 's/,$//'); [ -z "$P" ] || ps -o pid=,user=,etime= -p "$P"
    """
}

public enum SSHRunner {
    /// 用系统自带的 ssh 连服务器执行命令，带超时保护
    public static func run(config: ServerConfig, timeout: TimeInterval) async throws -> SSHResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                var arguments = [
                    "-o", "BatchMode=yes",                 // 免密失败就直接报错，不挂在那等输密码
                    "-o", "ConnectTimeout=5",
                    "-o", "StrictHostKeyChecking=accept-new", // 第一次连接自动记录主机指纹
                ]
                if config.user.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 用户名留空：主机填的是 ~/.ssh/config 里的别名，
                    // 地址、端口、密钥、跳板机等全部按配置里的来
                    arguments.append(config.host)
                } else {
                    arguments += ["-p", String(config.port), "\(config.user)@\(config.host)"]
                }
                arguments.append(GPURemote.command)
                process.arguments = arguments
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var timedOut = false
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: SSHError.launchFailed(error.localizedDescription))
                    return
                }
                process.waitUntilExit()

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = SSHResult(
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus)

                if timedOut {
                    cont.resume(throwing: SSHError.timeout)
                } else {
                    cont.resume(returning: result)
                }
            }
        }
    }
}
