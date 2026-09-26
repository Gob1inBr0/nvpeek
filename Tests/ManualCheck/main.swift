// 手动校验程序：这台机器的命令行工具没带 XCTest，跑不了 swift test，
// 用普通可执行程序把解析器的用例全部验一遍。
// 运行方式见 build.sh 里的 verify_parser 步骤。
import Foundation

var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("  ✅ \(name)")
    } else {
        failures += 1
        print("  ❌ \(name)")
    }
}

let sampleStdout = """
@@GPU@@
0, NVIDIA A100-SXM4-40GB, GPU-9f3a, 30214, 40960, 97, 65
1, NVIDIA A100-SXM4-40GB, GPU-9f3b, 512, 40960, 0, 38
2, NVIDIA A100-SXM4-40GB, GPU-9f3c, 20480, 40960, 43, 52
@@PROC@@
GPU-9f3a, 12345, python3, 28000
GPU-9f3a, 12346, "/path/with,comma/train.py", 2000
GPU-9f3c, 12347, python3, [N/A]
@@PS@@
12345 chen 2-03:12:33
12346 wang 1:22:03
12347 li 12:03:44
"""

print("== 完整输出解析 ==")
do {
    let (gpus, procs) = try Parser.parse(stdout: sampleStdout, stderr: "")
    check("读到 3 张卡", gpus.count == 3)
    check("利用率 97%", gpus[0].util == 97)
    check("显存占用 30214MiB", gpus[0].memUsedMiB == 30214)
    check("1 号卡判定空闲", gpus[1].isIdle)
    check("0 号卡判定非空闲", !gpus[0].isIdle)
    check("温度 52 度", gpus[2].temp == 52)
    check("读到 3 个进程", procs.count == 3)
    check("带逗号的命令名完整保留", procs[1].name == "/path/with,comma/train.py")
    check("用户名来自 ps 段", procs[0].user == "chen")
    check("运行时长来自 ps 段", procs[0].elapsed == "2-03:12:33")
    check("[N/A] 的进程显存是空值", procs[2].memMiB == nil)
    check("通过 uuid 对上显卡编号", procs[2].gpuIndex == 2)
} catch {
    failures += 1
    print("  ❌ 不应该抛错：\(error)")
}

print("== 错误情况 ==")
do {
    _ = try Parser.parse(stdout: "", stderr: "bash: nvidia-smi: command not found")
    failures += 1
    print("  ❌ 应该抛错却没抛")
} catch let e as ParseError {
    if case .remote(let msg) = e {
        check("错误信息带 stderr 内容", msg.contains("command not found"))
    } else {
        failures += 1; print("  ❌ 错误类型不对：\(e)")
    }
} catch {
    failures += 1; print("  ❌ 错误类型不对：\(error)")
}

do {
    _ = try Parser.parse(stdout: "", stderr: "")
    failures += 1
    print("  ❌ 应该抛错却没抛")
} catch let e as ParseError {
    if case .remote(let msg) = e {
        check("空输出给出 nvidia-smi 提示", msg.contains("nvidia-smi"))
    } else {
        failures += 1; print("  ❌ 错误类型不对：\(e)")
    }
} catch {
    failures += 1; print("  ❌ 错误类型不对：\(error)")
}

print("== 空闲机器（无进程） ==")
do {
    let stdout = """
    @@GPU@@
    0, NVIDIA RTX 4090, GPU-abc, 200, 24564, 0, 35
    @@PROC@@
    @@PS@@
    """
    let (gpus, procs) = try Parser.parse(stdout: stdout, stderr: "")
    check("读到 1 张卡", gpus.count == 1)
    check("进程数为 0", procs.count == 0)
    check("判定空闲", gpus[0].isIdle)
} catch {
    failures += 1; print("  ❌ 不应该抛错：\(error)")
}

print("== CSV 解析 ==")
check("基本逗号分隔", Parser.csvFields("1, b , c") == ["1", "b", "c"])
check("引号内逗号不分隔", Parser.csvFields("a, \"x,y\", 3") == ["a", "x,y", "3"])
check("双引号转义", Parser.csvFields("\"he said \"\"hi\"\"\", 2") == ["he said \"hi\"", "2"])
check("[N/A] 原样保留", Parser.csvFields("GPU-uuid, 123, [N/A]") == ["GPU-uuid", "123", "[N/A]"])

print("== 远端命令字符串 ==")
check("包含显卡状态查询", GPURemote.command.contains("--query-gpu=index,name,uuid,memory.used,memory.total,utilization.gpu,temperature.gpu"))
check("包含计算进程查询", GPURemote.command.contains("--query-compute-apps=gpu_uuid,pid,process_name,used_memory"))
check("包含 ps 查询", GPURemote.command.contains("ps -o pid=,user=,etime="))

print("== ssh 配置解析 ==")
do {
    let tmp = FileManager.default.temporaryDirectory
    let included = tmp.appendingPathComponent("gpuwidget_test_included.conf")
    let main = tmp.appendingPathComponent("gpuwidget_test_main.conf")
    try """
    Host gpu2 lab-box
      HostName lab.example.com
      User root

    Host *
      User fallback
    """.write(toFile: included.path, atomically: true, encoding: .utf8)
    try """
    # 普通条目
    Host gpu1
      HostName 10.0.0.1
      User chen
      Port 2222

    Include \(included.path)

    Host broken
      Port not-a-number
    """.write(toFile: main.path, atomically: true, encoding: .utf8)

    let entries = SSHConfigParser.parse(fileURLs: [main])
    check("读到 4 台（Include 展开 + 逗号别名拆开）", entries.count == 4)
    check("顺序：gpu1 在最前", entries.first?.alias == "gpu1")
    let gpu1 = entries.first { $0.alias == "gpu1" }
    check("gpu1 地址 10.0.0.1", gpu1?.hostname == "10.0.0.1")
    check("gpu1 用户 chen", gpu1?.user == "chen")
    check("gpu1 端口 2222", gpu1?.port == 2222)
    let gpu2 = entries.first { $0.alias == "gpu2" }
    check("gpu2 用户 root（不被 Host * 的 fallback 覆盖）", gpu2?.user == "root")
    let labBox = entries.first { $0.alias == "lab-box" }
    check("lab-box 和 gpu2 共用配置", labBox?.hostname == "lab.example.com" && labBox?.user == "root")
    check("没有把 Host * 这种模式列出来", !entries.contains { $0.alias.contains("*") })
    let broken = entries.first { $0.alias == "broken" }
    check("端口写错时忽略（记为 22 直连）", broken?.port == nil)
    check("不存在的文件返回空列表", SSHConfigParser.parse(fileURLs: [tmp.appendingPathComponent("no_such_file")]).isEmpty)
} catch {
    failures += 1
    print("  ❌ 测试文件写入失败：\(error)")
}

print("== 显示设置 ==")
do {
    let encoded = try JSONEncoder().encode(DisplayPrefs())
    let back = try JSONDecoder().decode(DisplayPrefs.self, from: encoded)
    check("DisplayPrefs 编解码往返一致", back == DisplayPrefs())
    let empty = try JSONDecoder().decode(DisplayPrefs.self, from: Data("{}".utf8))
    check("老配置缺字段时用默认值（钉桌面）", empty == DisplayPrefs() && empty.mode == .desktop)
    check("默认快捷键 ⌥⇧G", empty.hotkeyLabel == "⌥⇧G" && empty.hotkeyCode == 0x22)
    var changed = DisplayPrefs()
    changed.mode = .floating
    changed.collapsed = true
    let reencoded = try JSONDecoder().decode(DisplayPrefs.self, from: try JSONEncoder().encode(changed))
    check("改过的值（悬浮+迷你）正确保存", reencoded.mode == .floating && reencoded.collapsed)
} catch {
    failures += 1
    print("  ❌ DisplayPrefs 编解码异常：\(error)")
}

if failures == 0 {
    print("\n全部通过 🎉")
    exit(0)
} else {
    print("\n有 \(failures) 个用例失败")
    exit(1)
}
