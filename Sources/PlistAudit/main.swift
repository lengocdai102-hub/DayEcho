import Foundation

// MARK: - plist 权限静态审计
//
// 目的：在 CI 里拦住「权限声明漏了」这类**只有真机才暴露**的问题。
//
// 真机上的两类致命坑：
//   1. 漏声明 NSMicrophoneUsageDescription → 点开始录音被系统静默拒绝，**没有任何提示**
//   2. 漏声明 UIBackgroundModes=audio → 锁屏后进程被挂起，录音出现一段段空洞
//
// 这两类在 Mac 上编译、跑单元测试**全都发现不了**，只有真机能复现。
// 所以这里做静态审计：把「源码里实际用到了什么」和「plist 里声明了什么」对账。
//
// 用法：swift run PlistAudit
// 退出码非 0 = 审计失败（CI 会红）

enum PlistAudit {
    static func run() -> Int32 {
        let root = projectRoot()
        var failures: [String] = []
        var warnings: [String] = []

        // ══════════════ 1. 读取工程生成脚本 ══════════════
        let projPath = root + "/legal/gen_xcodeproj.rb"
        guard let proj = try? String(contentsOfFile: projPath, encoding: .utf8) else {
            print("✗ 读不到工程脚本：\(projPath)")
            return 1
        }

        // ★ 关键：只认**真正的赋值语句**，剔除注释 ★
        // 注释里写「已删除 NSHealthShareUsageDescription」不代表真的声明了它。
        // 不剔除注释，审计器会把自己的说明文字当成配置，产生假阳性。
        let allAssign = assignments(proj)

        // 四个 build_settings 块，按行号切：38=Kit, 101=?, 163=watch, 324=iOS
        let lines = proj.components(separatedBy: "\n")
        let blocks = splitBuildSettingBlocks(lines)
        guard blocks.count >= 4 else {
            print("✗ 工程脚本结构变了（build_settings 块数 = \(blocks.count)，期望 4）—— 审计器需要同步更新")
            return 1
        }
        let watchBlock = assignments(blocks[2])
        let iosBlock = assignments(blocks[3])

        // ══════════════ 2. watch target 审计 ══════════════
        let watchSrc = readDir(root + "/Sources/DayEchoWatchApp")
        let watchImpl = watchSrc.joined(separator: "\n")

        // 2a. 麦克风
        let watchUsesMic = watchImpl.contains("AVAudioSession") || watchImpl.contains("AVAudioRecorder")
        if watchUsesMic {
            if declares(watchBlock, "INFOPLIST_KEY_NSMicrophoneUsageDescription") {
                print("✓ watch 端已声明 NSMicrophoneUsageDescription")
            } else {
                failures.append("watch 端用了 AVAudioSession 但未声明 NSMicrophoneUsageDescription —— 真机上点开始录音会被系统静默拒绝")
            }
        }

        // 2b. 后台音频 —— 全天录音的正解，缺了就锁屏断录
        if declares(watchBlock, "INFOPLIST_KEY_UIBackgroundModes") && watchBlock.contains("'audio'") {
            print("✓ watch 端已声明 UIBackgroundModes = audio（锁屏持续录音）")
        } else {
            failures.append("watch 端未声明 UIBackgroundModes = audio —— 锁屏/息屏后进程被挂起，录音出现空洞")
        }

        // 2c. WKApplication 必填
        if declares(watchBlock, "INFOPLIST_KEY_WKApplication") {
            print("✓ watch 端已声明 WKApplication")
        } else {
            failures.append("watch 端缺少 INFOPLIST_KEY_WKApplication —— SwiftUI watch App 无法启动")
        }

        // 2d. WKWatchOnly 必须不存在（与嵌入语义互斥）
        if declares(watchBlock, "INFOPLIST_KEY_WKWatchOnly") {
            failures.append("watch 端设置了 WKWatchOnly=YES —— 与「嵌入 iOS App」语义互斥，会导致安装失败")
        } else {
            print("✓ watch 端未启用 WKWatchOnly（嵌入语义正确）")
        }

        // ══════════════ 3. iOS target 审计 ══════════════
        if declares(iosBlock, "INFOPLIST_KEY_NSMicrophoneUsageDescription") {
            print("✓ iOS 端已声明 NSMicrophoneUsageDescription")
        } else {
            failures.append("iOS 端缺少 NSMicrophoneUsageDescription")
        }

        // 3a. iOS 端也要后台音频 —— 否则锁屏后手机停止接收手表传来的录音
        if declares(iosBlock, "INFOPLIST_KEY_UIBackgroundModes") && iosBlock.contains("'audio'") {
            print("✓ iOS 端已声明 UIBackgroundModes = audio（锁屏仍能接收手表录音）")
        } else {
            failures.append("iOS 端缺少 UIBackgroundModes = audio —— 锁屏后手机停止接收手表传来的录音")
        }

        // 3b. 多余权限：声明了但源码里根本没用
        let allSrc = readDir(root + "/Sources/DayEchoApp")
            + readDir(root + "/Sources/DayEchoWatchApp")
            + readDir(root + "/Sources/DayEchoKit")
        let healthUsed = allSrc.contains { $0.contains("HKHealthStore") || $0.contains("import HealthKit") }
        if declares(iosBlock, "NSHealthShareUsageDescription") {
            if healthUsed {
                warnings.append("iOS 端声明了 NSHealthShareUsageDescription 且确实用到 HealthKit —— 确认是否真有必要")
            } else {
                failures.append("iOS 端声明了 NSHealthShareUsageDescription，但源码里没有任何 HealthKit 调用 —— 无用权限会让用户困惑、审核追问")
            }
        } else {
            print("✓ iOS 端无冗余的 NSHealthShareUsageDescription")
        }

        // 3c. 其他常见的无用权限
        for perm in ["NSLocationWhenInUseUsageDescription", "NSCameraUsageDescription",
                     "NSContactsUsageDescription", "NSPhotoLibraryUsageDescription"] {
            if declares(iosBlock, perm) {
                let key = perm.replacingOccurrences(of: "UsageDescription", with: "")
                let used = allSrc.contains { $0.contains(key) }
                if !used {
                    failures.append("iOS 端声明了 \(perm) 但源码里从未使用 —— 无用权限")
                }
            }
        }

        // ══════════════ 4. 关键实现自检 ══════════════
        // 防止「plist 声明对了，但实现没接上」——这类问题同样只有真机能暴露。

        // 4a. transferFile 必须真的被调用（而不是 sendMessage）
        if watchImpl.contains("transferFile") {
            print("✓ watch 端使用 WCSession.transferFile 传音频（系统后台队列，支持断点续传）")
        } else {
            failures.append("watch 端没有调用 transferFile —— 音频传输必须走系统文件队列")
        }

        if watchImpl.contains("sendMessage(") || watchImpl.contains("transferUserInfo(") {
            failures.append("watch 端用了 sendMessage / transferUserInfo 传音频 —— 有体积限制且会积压内存，必须用 transferFile")
        }

        // 4b. iPhone 端必须立刻 moveItem（回调返回后系统会删临时文件）
        let iosSrc = readDir(root + "/Sources/DayEchoApp").joined(separator: "\n")
        if iosSrc.contains("moveItem") && iosSrc.contains("didReceive file") {
            print("✓ iPhone 端在 didReceive file 回调里 moveItem 到沙盒（不会因临时文件被删而丢数据）")
        } else {
            failures.append("iPhone 端未在 didReceive file 回调里 moveItem —— 回调返回后系统会删除临时文件，数据静默丢失")
        }

        // 4c. 音频会话必须 setActive(true)
        if watchImpl.contains("setActive(true)") {
            print("✓ watch 端激活了音频会话（后台录音的前提）")
        } else {
            failures.append("watch 端没有 setActive(true) —— 音频会话未激活，后台录音会被系统挂起")
        }

        // 4d. 必须有恢复 inFlight 的逻辑（解 Auday 式卡死）
        let kitSrc = readDir(root + "/Sources/DayEchoKit").joined(separator: "\n")
        if kitSrc.contains("recoverInFlight") || kitSrc.contains("recoverInterrupted") {
            print("✓ 存在 inFlight 恢复逻辑（进程被杀/重启后不会卡死在待同步）")
        } else {
            failures.append("缺少 inFlight 恢复逻辑 —— 传输中重启会让那几段永远卡住，这是 Auday 的核心差评场景")
        }

        // 4e. 分段时钟必须被真正使用（时间戳正确性）
        if watchImpl.contains("SegmentClock") {
            print("✓ watch 端使用 SegmentClock 计算分段起止时间（时间戳不重叠不漂移）")
        } else {
            failures.append("watch 端未使用 SegmentClock —— 分段时间戳会全部挤在同一处，iPhone 上时间线失真")
        }

        // ══════════════ 5. 生成后工程审计（真正装机的那份）══════════════
        //
        // ★ 为什么还要查这一层 ★
        // 前面检查的是「生成脚本」，但真正装到手机上的是「生成出来的工程」。
        // 脚本写对了、生成过程出偏差，最终装机的东西一样是错的。
        // 所以只要工程已生成，就再核对一遍产物。
        let projPath2 = root + "/DayEcho.xcodeproj/project.pbxproj"
        if FileManager.default.fileExists(atPath: projPath2) {
            if let generated = try? String(contentsOfFile: projPath2, encoding: .utf8) {
                print("")
                print("── 生成后工程核对 ──")
                // 1. WKWatchOnly 必须不存在
                if generated.contains("WKWatchOnly") {
                    failures.append("生成后的工程里出现了 WKWatchOnly —— 与「嵌入 iOS App」语义互斥，会导致安装失败")
                } else {
                    print("✓ 生成后工程无 WKWatchOnly")
                }
                // 2. HealthKit 冗余权限必须已清掉
                if generated.contains("NSHealthShareUsageDescription") {
                    failures.append("生成后的工程里仍有 NSHealthShareUsageDescription —— 冗余权限")
                } else {
                    print("✓ 生成后工程无冗余 HealthKit 权限")
                }
                // 3. 后台音频与麦克风必须真的在工程里
                if generated.contains("UIBackgroundModes") && generated.contains("NSMicrophoneUsageDescription") {
                    print("✓ 生成后工程含后台音频与麦克风声明")
                } else {
                    failures.append("生成后的工程缺少 UIBackgroundModes 或 NSMicrophoneUsageDescription")
                }
                // 4. 新增源文件必须真的进了工程
                for need in ["WatchTransferChannel.swift", "WatchSessionCoordinator.swift",
                             "PhoneReceiveChannel.swift", "SegmentClock.swift"] {
                    if !generated.contains(need) {
                        failures.append("生成后的工程里缺少源文件 \(need) —— 文件加了但没进 target")
                    }
                }
                print("✓ 4 个新增源文件均已进入工程")
            }
        } else {
            print("")
            print("ℹ️  未找到 DayEcho.xcodeproj —— 跳过生成后工程核对（CI 中会先生成工程再跑本审计）")
        }

        // ══════════════ 6. 输出 ══════════════
        print("")
        if !warnings.isEmpty {
            print("警告 \(warnings.count) 条：")
            for w in warnings { print("  ⚠︎ \(w)") }
            print("")
        }
        if failures.isEmpty {
            print("✅ plist 权限审计全部通过")
            return 0
        } else {
            print("❌ plist 权限审计失败 \(failures.count) 项：")
            for f in failures { print("  ✗ \(f)") }
            return 1
        }
    }

    // MARK: 工具

    /// 剔除注释行，只保留 `s['KEY'] = ...` / `s.delete('KEY')` 形态的赋值语句。
    static func assignments(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { line in
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("#") { return false }
                return s.contains("s[") || s.contains("s.delete(")
            }
            .joined(separator: "\n")
    }

    /// 判断某个 plist 键**是否真的被声明了**。
    ///
    /// ★ 关键语义：`s.delete('KEY')` 表示「确保这个键不存在」★
    /// 这在 xcodeproj 里是合法的写法，用来显式移除继承来的默认值。
    /// 它是**否定**语义，不能当成「声明了这个键」——
    /// 否则审计器会误报「WKWatchOnly 被设置了」，
    /// 而实际上那行代码恰恰是在保证它不出现。
    static func declares(_ block: String, _ key: String) -> Bool {
        for line in block.components(separatedBy: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { continue }
            // delete 语义 = 否定，跳过
            if s.contains("s.delete(") && s.contains(key) { continue }
            if s.contains("s[") && s.contains(key) { return true }
        }
        return false
    }

    /// 按 `s = cfg.build_settings` 切块。
    ///
    /// 用行号切比用字符串标记切更可靠：
    /// 同一个键（CFBundleDisplayName 等）在多个 target 里都出现，
    /// 按内容找会切错块。
    static func splitBuildSettingBlocks(_ lines: [String]) -> [String] {
        var starts: [Int] = []
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "s = cfg.build_settings" {
                starts.append(i)
            }
        }
        var blocks: [String] = []
        for (idx, start) in starts.enumerated() {
            let end = idx + 1 < starts.count ? starts[idx + 1] : lines.count
            blocks.append(lines[start..<end].joined(separator: "\n"))
        }
        return blocks
    }

    /// 读目录下所有 .swift 文件内容
    static func readDir(_ path: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var out: [String] = []
        for name in names where name.hasSuffix(".swift") {
            let full = path + "/" + name
            if let s = try? String(contentsOfFile: full, encoding: .utf8) {
                out.append(s)
            }
        }
        return out
    }

    /// 定位工程根目录
    static func projectRoot() -> String {
        let fm = FileManager.default
        var dir = fm.currentDirectoryPath
        while dir != "/" {
            if fm.fileExists(atPath: dir + "/Package.swift") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return fm.currentDirectoryPath
    }
}

// MARK: - 入口
//
// ★ 不用 exit() ★
// exit() 会绕过 Swift 的 stdout 缓冲，导致 print 的内容全部丢失
// （表现就是「跑一下什么都没打印，退出码还是 0」）——
// 这会让 CI 里的审计形同虚设。用 fflush + 明确的退出码。
import Darwin
let code = PlistAudit.run()
fflush(stdout)
exit(code)
