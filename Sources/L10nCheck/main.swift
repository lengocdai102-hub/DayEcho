import Foundation

// Bundle.localizedString 按系统语言偏好走，测不到单个 lproj 的内容。
// 这里直接读每个 .lproj 的 .strings 文件，逐个校验翻译内容。
// 检查两件事：① 必需键在每个 lproj 都存在；② 各 lproj 键集合完全一致（防漏翻）。
let bundle = Bundle.module

let required = ["备份体检", "录音时间线", "导出与备份", "检查", "数据完整", "需要处理",
                "暂无录音", "录音段数", "占用空间", "缺失文件", "校验不符", "序列缺口"]

var failed = 0
var keySets: [String: Set<String>] = [:]

for lang in ["zh-Hans", "en"] {
    guard let path = bundle.path(forResource: lang, ofType: "lproj") else {
        print("X 找不到 " + lang + ".lproj")
        failed += 1
        continue
    }
    print("== " + lang + ".lproj ==")
    let dict = NSDictionary(contentsOfFile: path + "/Localizable.strings") as? [String: String] ?? [:]
    keySets[lang] = Set(dict.keys)
    for key in required {
        if let v = dict[key] {
            print("   OK " + key + " -> " + v)
        } else {
            print("   X 缺失 " + key)
            failed += 1
        }
    }
}

// 键集合一致性
if keySets.count == 2, let zh = keySets["zh-Hans"], let en = keySets["en"] {
    let onlyZh = zh.subtracting(en)
    let onlyEn = en.subtracting(zh)
    if !onlyZh.isEmpty {
        print("X 仅 zh-Hans 存在: " + onlyZh.sorted().joined(separator: ", "))
        failed += 1
    }
    if !onlyEn.isEmpty {
        print("X 仅 en 存在: " + onlyEn.sorted().joined(separator: ", "))
        failed += 1
    }
    if onlyZh.isEmpty && onlyEn.isEmpty {
        print("== 键集合一致 (" + String(zh.count) + " 键) ==")
    }
}

print("")
print("失败 " + String(failed) + " 项")
if failed > 0 { exit(1) }
