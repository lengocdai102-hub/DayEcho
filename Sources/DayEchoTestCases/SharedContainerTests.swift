import Foundation
import DayEchoKit

/// ★ 阶段 1.3 验收测试：App Group 与跨进程落盘 ★
///
/// ★ 这些测试不依赖真机 ★
///
/// App Group 的真实 container URL 因设备而异，无法在测试里硬编码。
/// 但**目录结构、文件命名、写入方式、读取语义**全都可以用临时目录验证。
/// 这正是「把路径解析抽成可注入」的价值。
public enum SharedContainerTests {

    public static func run() throws {
        // MARK: - 目录解析

        Suite.case_("目录：注入路径时完全跳过 App Group 探测") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            let resolved = SharedContainer.rootURL(override: tmp)
            try Suite.equal(resolved.path, tmp.path, "注入路径必须原样返回")
            try Suite.isTrue(!SharedContainer.isUsingAppGroup(override: tmp),
                             "注入路径时不应声称在用 App Group")
        }

        Suite.case_("目录：四个子目录名固定") {
            // ★ 这些字符串会被扩展进程和主进程分别使用 ★
            // 改任何一个都会让跨进程投递断掉 ⇒ 用测试钉死。
            try Suite.equal(SharedContainer.incomingPayloadsDirectory, "IncomingPayloads")
            try Suite.equal(SharedContainer.recordingsDirectory, "Recordings")
            try Suite.equal(SharedContainer.transcriptsDirectory, "Transcripts")
            try Suite.equal(SharedContainer.quarantineDirectory, "Quarantine")
            try Suite.equal(SharedContainer.appGroupIdentifier, "group.com.dayecho.app.H98V6YZ5QL")
        }

        Suite.case_("目录：子目录路径挂在共享根目录下") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            let d = SharedContainer.directory(SharedContainer.recordingsDirectory, override: tmp)
            try Suite.isTrue(d.path.hasPrefix(tmp.path), "子目录必须在注入根目录之下")
            try Suite.isTrue(d.lastPathComponent == "Recordings")
        }

        Suite.case_("目录：ensureDirectory 真的建目录") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            let url = try SharedContainer.ensureDirectory(
                SharedContainer.transcriptsDirectory, override: tmp)
            var isDir: ObjCBool = false
            try Suite.isTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
            try Suite.isTrue(isDir.boolValue, "应该是目录")
            try? FileManager.default.removeItem(at: tmp)
        }

        // MARK: - 跨进程落盘

        Suite.case_("跨进程：写入 → 读取 → 内容一致") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let store = IncomingPayloadStore(root: tmp)
            let entry = IngestedTextEntry(
                source: .shareExtension,
                text: "提醒我明天上午十点交房租",
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try store.write(IncomingPayload(entry: entry))

            let loaded = store.loadAll()
            try Suite.equal(loaded.payloads.count, 1, "应读到 1 条")
            try Suite.equal(loaded.corrupt.count, 0, "不该有损坏文件")
            try Suite.equal(loaded.payloads.first?.entry.text ?? "", entry.text)
            try Suite.equal(loaded.payloads.first?.entry.source, .shareExtension)
            try Suite.equalAccuracy(
                loaded.payloads.first?.entry.occurredAt.timeIntervalSince1970 ?? 0,
                1_700_000_000, 1, "occurredAt 应精确往返")
        }

        Suite.case_("跨进程：consumeAll 读后删除，重复调用不报错") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let store = IncomingPayloadStore(root: tmp)
            for i in 0..<3 {
                try store.write(IncomingPayload(entry: IngestedTextEntry(
                    source: .shortcutIntent, text: "第\(i)条", occurredAt: Date())))
            }
            let first = store.consumeAll()
            try Suite.equal(first.payloads.count, 3, "第一次应读到 3 条")

            let second = store.consumeAll()
            try Suite.equal(second.payloads.count, 0, "第二次应为空")
            try Suite.equal(second.corrupt.count, 0)
        }

        Suite.case_("跨进程：载荷按写入时间排序") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let store = IncomingPayloadStore(root: tmp)
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            // 故意乱序写入
            for offset in [30.0, 10.0, 20.0] {
                try store.write(IncomingPayload(
                    entry: IngestedTextEntry(
                        source: .shortcutIntent, text: "t\(offset)", occurredAt: base),
                    writtenAt: base.addingTimeInterval(offset)))
            }
            let loaded = store.loadAll()
            let texts = loaded.payloads.map { $0.entry.text }
            try Suite.equal(texts.joined(separator: ","), "t10.0,t20.0,t30.0", "应按写入时间升序")
        }

        Suite.case_("跨进程：损坏文件不拖垮整批，且被隔离而不是删除") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let store = IncomingPayloadStore(root: tmp)
            // 一好一坏
            try store.write(IncomingPayload(entry: IngestedTextEntry(
                source: .shareExtension, text: "好的那条", occurredAt: Date())))
            try "{ 这不是合法 JSON".write(
                to: tmp.appendingPathComponent("broken.json"),
                atomically: true, encoding: .utf8)

            let loaded = store.loadAll()
            try Suite.equal(loaded.payloads.count, 1, "好文件仍应被读到")
            try Suite.equal(loaded.corrupt.count, 1, "坏文件应被标记")

            let moved = store.quarantineCorrupt(loaded.corrupt)
            try Suite.equal(moved.count, 1, "坏文件应被挪到隔离区")
            try Suite.isTrue(FileManager.default.fileExists(atPath: moved[0].path),
                             "隔离后文件仍在（不删）")
            try Suite.isTrue(moved[0].path.contains(SharedContainer.quarantineDirectory),
                             "应在 Quarantine 目录下")

            // 好文件仍在原处（隔离只针对损坏的）
            let after = store.loadAll()
            try Suite.equal(after.payloads.count, 1, "好文件不受隔离影响")
        }

        Suite.case_("跨进程：同名 payload id 不覆盖（文件名唯一）") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let store = IncomingPayloadStore(root: tmp)
            let entry = IngestedTextEntry(
                source: .shareExtension, text: "同一个", occurredAt: Date())
            let p1 = IncomingPayload(id: UUID(), entry: entry)
            let p2 = IncomingPayload(id: UUID(), entry: entry)
            try store.write(p1)
            try store.write(p2)
            try Suite.equal(store.loadAll().payloads.count, 2, "两个独立载荷都在")
        }

        // MARK: - 落盘格式

        Suite.case_("落盘：JSON 可被独立进程解析（不依赖 Swift 类型信息）") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let store = IncomingPayloadStore(root: tmp)
            try store.write(IncomingPayload(entry: IngestedTextEntry(
                source: .watchCapture, text: "提醒我吃药", occurredAt: Date())))

            let files = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            try Suite.equal(files.count, 1)
            let data = try Data(contentsOf: tmp.appendingPathComponent(files[0]))

            // 用裸 JSON 解析，不走 IncomingPayload 的 Codable
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try Suite.isTrue(obj != nil, "应是合法 JSON 对象")
            let entry = obj?["entry"] as? [String: Any]
            try Suite.isTrue(entry != nil, "应含 entry 字段")
            try Suite.equal(entry?["text"] as? String ?? "", "提醒我吃药")
        }

        Suite.case_("落盘：临时文件不残留（原子写不留残骸）") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let store = IncomingPayloadStore(root: tmp)
            for i in 0..<5 {
                try store.write(IncomingPayload(entry: IngestedTextEntry(
                    source: .shareExtension, text: "第\(i)条", occurredAt: Date())))
            }
            let files = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            let temps = files.filter { $0.hasPrefix(".") }
            try Suite.equal(temps.count, 0, "不应有 .tmp- 残骸，实际：\(temps)")
            try Suite.equal(files.count, 5)
        }
    }
}
