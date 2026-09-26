import XCTest
@testable import nvpeekCore

final class ParserTests: XCTestCase {

    static let sampleStdout = """
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

    func testParseFullOutput() throws {
        let (gpus, procs) = try Parser.parse(stdout: Self.sampleStdout, stderr: "")

        XCTAssertEqual(gpus.count, 3)
        XCTAssertEqual(gpus[0].util, 97)
        XCTAssertEqual(gpus[0].memUsedMiB, 30214)
        XCTAssertEqual(gpus[1].isIdle, true)
        XCTAssertEqual(gpus[0].isIdle, false)
        XCTAssertEqual(gpus[2].temp, 52)

        XCTAssertEqual(procs.count, 3)
        // 带逗号的命令名要完整保留
        XCTAssertEqual(procs[1].name, "/path/with,comma/train.py")
        // 用户名来自 ps 段
        XCTAssertEqual(procs[0].user, "chen")
        XCTAssertEqual(procs[0].elapsed, "2-03:12:33")
        // [N/A] 的显存读不出来
        XCTAssertNil(procs[2].memMiB)
        // 显卡编号通过 uuid 对上
        XCTAssertEqual(procs[2].gpuIndex, 2)
    }

    func testNoGPUThrowsRemoteError() {
        XCTAssertThrowsError(try Parser.parse(stdout: "", stderr: "bash: nvidia-smi: command not found")) { error in
            guard case ParseError.remote(let msg) = error else {
                return XCTFail("应该是 remote 错误，实际是 \(error)")
            }
            XCTAssertTrue(msg.contains("command not found"))
        }
    }

    func testNoGPUWithEmptyStderr() {
        XCTAssertThrowsError(try Parser.parse(stdout: "", stderr: "")) { error in
            guard case ParseError.remote(let msg) = error else {
                return XCTFail("应该是 remote 错误，实际是 \(error)")
            }
            XCTAssertTrue(msg.contains("nvidia-smi"))
        }
    }

    func testIdleMachineHasNoProcesses() throws {
        let stdout = """
        @@GPU@@
        0, NVIDIA RTX 4090, GPU-abc, 200, 24564, 0, 35
        @@PROC@@
        @@PS@@
        """
        let (gpus, procs) = try Parser.parse(stdout: stdout, stderr: "")
        XCTAssertEqual(gpus.count, 1)
        XCTAssertEqual(procs.count, 0)
        XCTAssertEqual(gpus[0].isIdle, true)
    }

    func testCSVFields() {
        XCTAssertEqual(Parser.csvFields("1, b , c"), ["1", "b", "c"])
        XCTAssertEqual(Parser.csvFields("a, \"x,y\", 3"), ["a", "x,y", "3"])
        XCTAssertEqual(Parser.csvFields("\"he said \"\"hi\"\"\", 2"), ["he said \"hi\"", "2"])
        XCTAssertEqual(Parser.csvFields("GPU-uuid, 123, [N/A]"), ["GPU-uuid", "123", "[N/A]"])
    }
}
