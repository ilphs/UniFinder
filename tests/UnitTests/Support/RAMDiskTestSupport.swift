import Foundation

/// 볼륨 간(cross-volume) 시나리오 재현용 램디스크 헬퍼.
/// 테스트계획서 §2 — `hdiutil attach -nomount ram://` 사용.
///
/// CI/샌드박스 환경에서는 `hdiutil`/`diskutil` 권한이 없어 실패할 수 있으므로,
/// 실패 시 `nil`을 돌려주고 호출자가 `XCTSkip`으로 우아하게 건너뛴다.
enum RAMDiskTestSupport {

    struct Disk {
        let mountPoint: URL
        let devicePath: String
    }

    /// 램디스크를 만들고 APFS로 포맷해 `/Volumes/<volumeName>`에 마운트한다.
    static func attach(sizeInMB: Int = 16, volumeName: String = "UniFinderTestRAMDisk") -> Disk? {
        let sectors = sizeInMB * 2048 // 512바이트 섹터 기준

        guard let device = run("/usr/bin/hdiutil", ["attach", "-nomount", "ram://\(sectors)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !device.isEmpty
        else { return nil }

        guard run("/usr/sbin/diskutil", ["eraseVolume", "APFS", volumeName, device]) != nil else {
            detach(devicePath: device)
            return nil
        }

        let mountPoint = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mountPoint.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            detach(devicePath: device)
            return nil
        }
        return Disk(mountPoint: mountPoint, devicePath: device)
    }

    static func detach(devicePath: String) {
        _ = run("/usr/bin/hdiutil", ["detach", devicePath, "-force"])
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
