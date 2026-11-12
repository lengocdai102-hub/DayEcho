import Foundation

// MARK: - 本地化一致性检查
//
// 检查两件事：
//   ① 必需键在每个 .lproj 都存在
//   ② 同一 target 的各 lproj 键集合完全一致（防漏翻）
//
// ★ 为什么直接读源目录而不是 Bundle.module ★
//
// 之前用 `resources: [.process("../DayEchoApp/Resources")]` 跨 target 引用资源，
// SwiftPM 报：
//     Found unhandled resource at .../Sources/DayEchoApp/Resources
// 连带 `swift test` 整个失败。
//
// 而且 resources 是**构建产物**的拷贝 —— 本地化校验要检查的恰恰是
// **源文件**（翻译文案就在那里），从构建产物里读是舍近求远。
//
// ★ 为什么 App 和 Watch 要分开校验 ★
//
// 两个 target 的 .lproj 是**两套独立的文案**：
//   App   有 16 个键（备份体检 / 录音时间线 / 导出与备份 / …）
//   Watch 有  5 个键（录音中 / 待传 / 标记 / 开始录音 / 停止录音）
//
// 之前只查 App 那套 ⇒ Watch 的 11 个缺失键全被漏掉 ——
// 而漏翻的键在真机上就是直接显示 key 本身（用户看到的是「录音中」三个字，
// 不是英文，不是空白）。这正是这个检查存在的意义。

// ★ 直接定位仓库里的 .lproj 目录 ★
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // L10nCheck/
    .deletingLastPathComponent()   // Sources/
    .deletingLastPathComponent()   // 仓库根

let appLprojDir = repoRoot.appendingPathComponent("Sources/DayEchoApp/Resources")
let watchLprojDir = repoRoot.appendingPathComponent("Sources/DayEchoWatchApp/WatchResources")

// ★ 两个 target 各自的必需键 ★
let appRequired = ["备份体检", "录音时间线", "导出与备份", "检查", "数据完整", "需要处理",
                   "暂无录音", "录音段数", "占用空间", "缺失文件", "校验不符", "序列缺口",
                   "分享导出包", "导出全部录音", "段", "标记"]

let watchRequired = ["录音中", "待传", "标记", "开始录音", "停止录音"]

var failed = 0

// MARK: - ① 逐 target × 逐语言 校验必需键

/// 每个 target 一组，内部比对各语言的键集合
final class TargetSpec {
    let label: String
    let lprojDir: URL
    let required: [String]
    let langs: [String]
    var keySets: [String: Set<String>] = [:]

    init(label: String, lprojDir: URL, required: [String], langs: [String]) {
        self.label = label
        self.lprojDir = lprojDir
        self.required = required
        self.langs = langs
    }
}

var specs = [
    TargetSpec(label: "App", lprojDir: appLprojDir, required: appRequired,
               langs: ["zh-Hans", "en"]),
    TargetSpec(label: "Watch", lprojDir: watchLprojDir, required: watchRequired,
               langs: ["zh-Hans", "en"]),
]

for spec in specs {
    print("== " + spec.label + " ==")

    for lang in spec.langs {
        let lprojPath = spec.lprojDir.appendingPathComponent(lang + ".lproj")
        let stringsPath = lprojPath.appendingPathComponent("Localizable.strings")

        guard FileManager.default.fileExists(atPath: stringsPath.path) else {
            print("  X 找不到 " + stringsPath.path)
            failed += 1
            continue
        }

        guard let dict = NSDictionary(contentsOfFile: stringsPath.path) as? [String: String] else {
            print("  X 解析失败 " + stringsPath.path)
            failed += 1
            continue
        }

        print("  -- " + lang + " --")
        for key in spec.required {
            if let v = dict[key] {
                print("     OK " + key + " -> " + v)
            } else {
                print("     X 缺失 " + key + "  [" + spec.label + "/" + lang + "]")
                failed += 1
            }
        }

        spec.keySets[lang] = Set(dict.keys)
    }

    // MARK: - ② 同一 target 内各语言键集合一致性

    if spec.keySets.count == spec.langs.count,
       let zh = spec.keySets["zh-Hans"], let en = spec.keySets["en"] {
        let onlyZh = zh.subtracting(en)
        let onlyEn = en.subtracting(zh)
        if !onlyZh.isEmpty {
            print("  X 仅 zh-Hans 存在 [" + spec.label + "]: " + onlyZh.sorted().joined(separator: ", "))
            failed += 1
        }
        if !onlyEn.isEmpty {
            print("  X 仅 en 存在 [" + spec.label + "]: " + onlyEn.sorted().joined(separator: ", "))
            failed += 1
        }
        if onlyZh.isEmpty && onlyEn.isEmpty {
            print("  == 键集合一致 (" + String(zh.count) + " 键) ==")
        }
    } else {
        print("  X " + spec.label + " 缺少语言文件，无法比对键集合")
        failed += 1
    }

    print("")
}

print("失败 " + String(failed) + " 项")
if failed > 0 { exit(1) }
print("✅ 全部通过")
