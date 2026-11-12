# DayEcho 构建卡点详细文档

- **日期**：2026-11-12
- **仓库**：`lengocdai102-hub/DayEcho`（私有）
- **本地路径**：`/Users/maike/Desktop/DayEcho`
- **文档状态**：✅ **全部卡点已解除**。最后一次 CI run `43236911252`（提交 `4090a2e`）双 runner 全绿，unsigned `.ipa` 已产出
- **文档性质**：已归档的构建踩坑记录 + 回归防线清单

---

## 一、一句话结论

**已全绿。** run `43236911252`（提交 `4090a2e`）在 `macos-15` 与 `macos-26` 两个 runner 上均 **success**：

- ✅ iOS 模拟器构建通过
- ✅ watchOS 模拟器构建通过
- ✅ **真机 arm64 设备构建通过**
- ✅ **watch App 真实嵌入宿主包**（`DayEcho.app/Watch/DayEchoWatch.app`）
- ✅ **unsigned `.ipa` 已产出**（macos-15: 92,468 B / macos-26: 92,537 B）

实测判据键值（来自 run `43236911252` 日志）：

```
host   CFBundleIdentifier                = com.dayecho.app
watch  CFBundleIdentifier                = com.dayecho.app.watchkitapp
watch  WKCompanionAppBundleIdentifier   = com.dayecho.app
watch  WKApplication                     = true
watch  WKWatchOnly                       = <NOT_SET>
watch  WKRunsIndependentlyOfCompanionApp = false
```

---

---

## 二、CI 流水线全貌

### 2.1 步骤级状态（run `43236911252`，提交 `4090a2e`，双 runner 全绿）

| # | 步骤 | 结果 |
|---|------|------|
| 1–8 | Set up / Checkout / Xcode 选择 / toolchain / 单测 20-20 / 本地化键检查 / API 可见性审计 / Swift 语法检查 | ✅ |
| 9 | Generate Xcode project | ✅ |
| 10 | **Assert Embed Watch Content phase is not a silent no-op** | ✅ 新增防线 |
| 11 | Build iOS app (simulator) | ✅ |
| 12 | Typecheck watchOS app | ✅ |
| 13 | Build watchOS app (simulator) | ✅ |
| 14 | Build for device (arm64, unsigned) | ✅ **已通过** |
| 15 | **Assert Watch App was copied into host bundle (post-build)** | ✅ 新增防线 |
| 16 | Inspect Embedded Watch App Info.plist (诊断，`if: failure()`) | ⏭️ 未触发（无失败） |
| 17 | Pre-Package Assertion (bundle id hierarchy) | ✅ |
| 18 | Archive for device and package unsigned `.ipa` | ✅ **产物已出** |
| 19 | Verify device binary is arm64 | ✅ |
| 20 | Verify watchOS app is embedded | ✅ |
| 21 | Collect/Upload artifacts | ✅ |

> 步骤 10 与 15 是本轮新增的两条防回退断言，详见第五章。

### 2.2 Runner 说明

CI 使用两个 macOS runner 矩阵（`macos-15` / `macos-26`），Intel 架构，秒级可用。
免费账户的 `arm64` 标签排队 90+ 分钟，**不可用**——详见 skill `github-actions-macos-runner-queue`。

### 2.3 关键历史 run 对照

| run | 提交 | 失败点 | 报错 |
|-----|------|--------|------|
| `43219936019` | `12953cb` | Build for device | `integer literal '8589934592' overflows when stored into 'Int'` |
| `43220806195` | `48be4ac` | Build for device | 同上（字面量写法未解决） |
| `43221439837` | `199d731` | Build for device | `WatchKit App doesn't contain any WatchKit Extensions.` |
| `43222057461` | `6a7f3b5` | Build for device | 同上（加入诊断步骤，拿到产物结构） |
| `43223029328` | `47cde1b` | Build for device | `...whose WKAppBundleIdentifier matches "..."` |
| `43223565279` | `40c0183` | Build for device | 同上 |
| `43224160785` | — | Build for device | 同上（补充 watch app Info.plist 诊断） |
| `43224778810` | `f49b55a` | Build for device | 同上（移除 `WKWatchOnly` 后**错误未变**） |
| `43228815640` | `1d5fd47` | Build for device | 同上（精准诊断拿到全部判据键值，**全部正确** → 排除判据假设） |
| `43231318347` | `9c9c791` | Verify watchOS app is embedded | 改现代单 target 后，编译 0 报错但 `.app` 里**没有 `Watch/` 目录**（静默跳过） |
| `43234100450` | `c7ea5e4` | Verify watchOS app is embedded | 同上（改 `SDKROOT=auto` **无效** → 证明 phase 本身空转） |
| **`43236911252`** | **`4090a2e`** | — | ✅ **全绿，unsigned `.ipa` 产出**（补 `dstPath` + `ATTRIBUTES` 后） |

> ⚠️ 报错文本的**变化本身是证据链**：每次修复都推进了 Xcode 的校验进度，直到最后一条不再变化，说明剩余判据尚未被满足。

---

## 三、已修复的 7 个真实缺陷（附证据）

### 缺陷 ①：`public struct` 的 memberwise init 跨模块不可见

**现象**
```
error: missing argument for parameter 'from' in call
```

**根因**
Swift 中 `public struct` 的 memberwise initializer 默认是 **internal** 可见性。跨模块（App 作为框架消费者）访问时唯一可见的 init 是 `Codable` 合成的 `public init(from:)`，于是编译器只看到 `init(from:)`，报「缺少 `from` 参数」。

**为什么之前没发现**
SwiftPM 的测试 target 与 Kit 同模块可见，测试全绿；只有当 App 真正作为框架消费者编译时才暴露。

**修复**
```swift
public struct IntegrityReport {
    // ...
    public init() { ... }   // 显式 public init
}
```

**防线**
`Sources/ApiAudit/main.swift` 新增「跨模块 public API 可见性审计」：把 Kit 编译成 module，再用外部消费者逐个构造 public 类型。

**破坏性验证**：移除 `public init()` → 审计立即报错；恢复 → 归零。

---

### 缺陷 ②：watchOS 设备构建的 32 位 `Int` 溢出 ★最隐蔽

**现象**
```
error: integer literal '8589934592' overflows when stored into 'Int'
```

**根因（关键）**
**Apple Watch 设备是 `arm64_32` 架构，32 位指针**，因此 watchOS 上的 `Int` 最大值只有 `2_147_483_647`（约 2 GiB）。

而 `RetentionPolicy.maxTotalBytes` 的默认值是 8 GiB：
```swift
maxTotalBytes: Int? = 8 * 1024 * 1024 * 1024   // = 8_589_934_592
```

**为什么各种尝试都无效**
| 写法 | 结果 |
|------|------|
| `8 * 1024 * 1024 * 1024` | 32 位溢出 |
| `Int(8) * 1024 * 1024 * 1024` | **仍溢出**——后续纯字面量仍按 32 位推断，整条表达式在常量折叠时按最小位宽算 |
| `8_589_934_592` 字面量 | 仍溢出——存不进 32 位 `Int` |

**为什么本机完全测不出来**
| 环境 | 是否报错 |
|------|----------|
| macOS 本地 `swift build` / `swift test` | ❌ 不报（64 位 `Int`） |
| iOS 模拟器 | ❌ 不报 |
| iOS 真机（arm64，64 位 `Int`） | ❌ 不报 |
| **watchOS 真机（arm64_32，32 位 `Int`）** | ✅ **必炸** |

即：**只有 watchOS 真机 Release 构建才能暴露此 bug**。Debug 构建不做常量折叠，同样不报。

**修复**
```swift
// Models.swift
public var maxTotalBytes: Int64?          // Int? → Int64?
public init(maxTotalBytes: Int64? = 8_589_934_592, ...)
```
```swift
// RecordingStore.swift —— 累加也必须用 64 位
var total = keep.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
```
单段 `byteCount` 是 `Int`（单段大小 32 位够用），但**累加**会溢出，所以累加器用 `Int64`。

字节数本就应使用 64 位类型，这是跨 32/64 位平台安全的正确选择。

**防线**
`Sources/ApiAudit/main.swift` 新增「32 位 Int 常量溢出审计」，扫描源码中的大数字常量。

**破坏性验证**：把字面量改回 `8 * 1024 * 1024 * 1024` → 审计立即报出 `Models.swift:101` 并警告「watchOS 必然溢出」；恢复 → 归零。

---

### 缺陷 ③：extension 的 `NSExtensionPointIdentifier` 嵌套位置错误

**现象**
```
error: WatchKit App doesn't contain any WatchKit Extensions.
Verify that the value of NSExtensionPointIdentifier in your
WatchKit Extension's Info.plist is set to com.apple.watchkit.
```

**根因**
原实现用 `INFOPLIST_KEY_NSExtensionPointIdentifier` 生成 Info.plist，但 `INFOPLIST_KEY_*` 只能生成**顶层键**：

```xml
<key>NSExtensionPointIdentifier</key>   ← 顶层，Xcode 不认
<string>com.apple.watchkit</string>
```

而 Xcode 的 `ValidateEmbeddedBinary` 要求该键嵌在 **`NSExtension` 字典**里：

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.watchkit</string>
</dict>
```

`INFOPLIST_KEY_*` **无法表达嵌套字典**，因此必须改用真实的 Info.plist 文件。

**修复**
- 新增 `legal/WatchExtension-Info.plist`，显式写 `NSExtension` 字典
- extension target 改 `GENERATE_INFOPLIST_FILE = NO` + `INFOPLIST_FILE = legal/WatchExtension-Info.plist`
- 去掉 `WKExtensionDelegateClassName`（SwiftUI 生命周期不需要 `NSExtensionPrincipalClass`；设了反而会去找不存在的 `ExtensionDelegate` 类）

---

### 缺陷 ④：extension 缺 `WKAppBundleIdentifier`

**现象**
```
error: WatchKit App doesn't contain any WatchKit Extensions whose
WKAppBundleIdentifier matches "com.dayecho.app.watchkitapp".
```

**根因**
extension 的 Info.plist 缺少 `WKAppBundleIdentifier`，其值必须**等于** Watch App 的 `CFBundleIdentifier`。

**修复**
```xml
<key>WKAppBundleIdentifier</key>
<string>$(WATCH_APP_BUNDLE_IDENTIFIER)</string>
```
由 `legal/gen_xcodeproj.rb` 从 `WATCH_BUNDLE_ID` 常量注入构建变量，保证与 bundle id 单一来源、不会漂移：
```ruby
s['WATCH_APP_BUNDLE_IDENTIFIER'] = WATCH_BUNDLE_ID
```

---

### 缺陷 ⑤：watch app 缺 `Embed App Extensions` copy phase

**根因**
生成脚本中 `watch_target` 只有 `add_dependency(watch_ext)`（构建顺序依赖），**没有任何 copy phase 把 `.appex` 拷进 `DayEchoWatch.app/PlugIns/`**。

工程文件层面当时长这样：
```ruby
watch_target.add_dependency(watch_ext)   # 只有依赖，没有嵌入
```

**修复**
新增 copy files phase，`dst_subfolder_spec = 13`（`plug_ins`，经 xcodeproj 1.28.1 源码核对确认映射）。

**验证证据（CI 诊断产物结构）**
```
DayEcho.app/PlugIns/DayEchoWatch.app/PlugIns/DayEchoWatchExtension.appex   ✓ 位置正确
```

---

### 缺陷 ⑥：watch 端用旧版 watchapp2 壳 + watchkit2-extension 布局 ★架构级★

**症状**（run `43224778810`）：

```
error: WatchKit App doesn't contain any WatchKit Extensions whose
WKAppBundleIdentifier matches "com.dayecho.app.watchkitapp".
```

**排查过程中被逐一证伪的假设**（全部有实测证据，不靠猜）：

| 假设 | 证伪证据 |
|------|---------|
| extension 的 `WKAppBundleIdentifier` 不对 | 实测 = `com.dayecho.app.watchkitapp` ✅ 与 watch app 的 `CFBundleIdentifier` **完全一致** |
| extension 的 `NSExtensionPointIdentifier` 不对 | 实测 = `com.apple.watchkit` ✅ |
| watch app 的 `WKWatchOnly=true` 冲突 | 实测 `<NOT_SET>` ✅ |
| `WKCompanionAppBundleIdentifier` 不匹配宿主 | 实测 = `com.dayecho.app` ✅ 与宿主一致 |
| watch app 的 `CFBundleIdentifier` 层级不对 | 实测 = `com.dayecho.app.watchkitapp` ✅ 是宿主 id 的子级 |

**决定性证据**（来自 Xcode 自己的校验命令行）：

```
ValidateEmbeddedBinary .../Release-watchos/DayEchoWatch.app/PlugIns/DayEchoWatchExtension.appex
    embeddedBinaryValidationUtility ...appex -info-plist-path .../DayEchoWatch.app/Info.plist

# watch app 的 Info.plist 用这个 product type 生成：
-producttype com.apple.product-type.application.watchapp2
```

**结论**：我们造的是 **watchOS 2.0 时代的旧布局**（watchapp2 壳 + 独立 watchkit2-extension），
但 extension 里装的是现代 SwiftUI `@main struct App` 入口 —— 没有 `NSExtensionPrincipalClass`，
`embeddedBinaryValidationUtility` 因此不认它是有效的 WatchKit Extension，
表现出来就是「找不到匹配的 extension」。

**两个佐证**：
- watch app 的 `WKApplication = <NOT_SET>`（现代 SwiftUI watch App 的标记键，旧布局不需要它）
- 产物里有 `_WatchKitStub/WK`（旧版 watchapp2 的专属标记）

**修复**：改用 **Xcode 14+ 的现代单 target 布局** ——
watchOS App 自己就是 `com.apple.product-type.application`，直接编译 `Sources/DayEchoWatchApp` 源码，
**不再有 extension target**。

工程变化（`legal/gen_xcodeproj.rb`）：

- 删除 `DayEchoWatchExtension` target 及其 `legal/WatchExtension-Info.plist`
- `DayEchoWatch` 改为 `:application` product type，直接含 watch 源码
- 删除 "Embed App Extensions" copy phase
- watch app 新增 `INFOPLIST_KEY_WKApplication = YES`
- watch app 新增 `INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp = NO`（依附式手表 App）

> ⚠️ **现代单 target 架构下，Watch App 的宿主嵌入路径是 `DayEcho.app/Watch/DayEchoWatch.app`，
> 不是旧版的 `DayEcho.app/PlugIns/*.appex`。** 文档与脚本里所有 `PlugIns/` 描述均已据此修正。

---

### 缺陷 ⑦：`PBXCopyFilesBuildPhase` 缺 `dstPath` → 整个 phase 被静默跳过 ★★最难查★★

**症状**：缺陷 ⑥ 修完后，编译全程 **0 报错**，但 archive 产出的 `DayEcho.app` 里
**根本没有 `Watch/` 目录** —— watch App 没被拷进宿主包。

**为什么最难查**：Xcode 遇到 `dstPath` 缺失/非法的 copy phase，**不报错**，
而是把整个 "Embed Watch Content" phase 当成**空操作**跳过。
唯一症状就是产物里少一个目录，排查起来毫无线索。

**破案方式**：不猜，直接对照**真实 Xcode 工程**。取 `Finb/Bark`（现代单 target watchOS App，CI 可正常打包）的
`project.pbxproj` 逐字比对，三处差异：

| 项 | Bark（能工作） | 我们（静默跳过） |
|----|----------------|------------------|
| `dstPath` | `"$(CONTENTS_FOLDER_PATH)/Watch"` | ❌ **缺失** |
| `dstSubfolderSpec` | `16` | ✅ `16` |
| `PBXBuildFile.settings` | `{ATTRIBUTES = (RemoveHeadersOnCopy, )}` | ❌ **缺失** |

**根因**：`legal/gen_xcodeproj.rb` 里用 xcodeproj 的
`symbol_dst_subfolder_spec = :products_directory` 只写了 `dstSubfolderSpec = 16`，
**不会自动写 `dstPath`**。缺 `dstPath` 时 Xcode 不知道该拷到哪，整个 phase 空转。

> 附带排除的假设：`SDKROOT = watchos` 曾被怀疑是根因，改成 `auto` 后**依然失败**，
> 证明 phase 本身就是空转的，与 SDKROOT 无关。

**修复**（`legal/gen_xcodeproj.rb`）：

```ruby
embed_phase = ios_target.new_copy_files_build_phase('Embed Watch Content')
embed_phase.symbol_dst_subfolder_spec = :products_directory
embed_phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'      # ← 关键
embed_phase.add_file_reference(watch_target.product_reference)
embed_phase.files.each do |bf|
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
```

**落盘验证**（`DayEcho.xcodeproj/project.pbxproj`）：

```
C3BCE62A0BE2DAC5551B6871 /* Embed Watch Content */ = {
    isa = PBXCopyFilesBuildPhase;
    buildActionMask = 2147483647;
    dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";
    dstSubfolderSpec = 16;
    files = ( E973D2FD77EED55531E0BF83 /* DayEchoWatch.app in Embed Watch Content */, );
    name = "Embed Watch Content";
    runOnlyForDeploymentPostprocessing = 0;
};
E973D2FD77EED55531E0BF83 /* ... */ = {isa = PBXBuildFile; fileRef = E437860F08EDDB9737A65182 /* DayEchoWatch.app */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };
```

---

## 四、已归档卡点（历史记录，保留供追溯）

### 4.1 当时的报错（run `43224778810`，提交 `f49b55a`）★已解除，见缺陷 ⑥★

```
error: WatchKit App doesn't contain any WatchKit Extensions whose
WKAppBundleIdentifier matches "com.dayecho.app.watchkitapp".
Verify that the value of WKAppBundleIdentifier in your WatchKit Extension's
Info.plist matches the value of CFBundleIdentifier in your WatchKit App's Info.plist.
```

### 4.2 已确认正确的事实

| 检查项 | 值 | 状态 |
|--------|-----|------|
| extension 位置 | `DayEchoWatch.app/PlugIns/DayEchoWatchExtension.appex` | ✅ 已实测 |
| extension `NSExtension.NSExtensionPointIdentifier` | `com.apple.watchkit` | ✅ 已实测 |
| extension `WKAppBundleIdentifier` | `com.dayecho.app.watchkitapp` | ✅ 已实测 |
| extension `CFBundleIdentifier` | `com.dayecho.app.watchkitapp.extension` | ✅ 已实测 |
| watch app `WKCompanionAppBundleIdentifier` | `com.dayecho.app` | ✅ 已实测 |
| watch app `WKWatchOnly` | 已从生成脚本移除 | ⚠️ **产物侧未确认** |
| watch app `CFBundleIdentifier` 实际值 | **未拿到** | ❌ **缺这个事实** |

### 4.3 当时的关键缺口

**watch app 产物 `Info.plist` 里的 `CFBundleIdentifier` 实际值尚未取到。**

诊断脚本虽然打印了 watch app 的 Info.plist 全量内容（`CFBundleName = DayEchoWatch`、`WKCompanionAppBundleIdentifier`、`CFBundlePackageType = APPL` 等均在输出中可见），但 `CFBundleIdentifier` 那一行**没有出现在可见输出里**，且本轮 run 的诊断输出在读取环节被日志截断。

两种可能性尚未区分：
1. watch app 产物里的 `CFBundleIdentifier` ≠ `com.dayecho.app.watchkitapp`（例如 `$(PRODUCT_BUNDLE_IDENTIFIER)` 在壳 target 上展开成了别的值，或生成脚本给壳设置的 bundle id 与 extension 的 `WKAppBundleIdentifier` 不同源）；
2. `WKWatchOnly` 虽然从脚本移除，但**该 run 的产物是移除前/后未确认**（提交 `f49b55a` 与 run `43224778810` 的对应关系需再核），产物里仍带 `WKWatchOnly=true`。

**（历史记录。后续已通过「精准诊断 + 真实工程对照」两条路径拿到事实并修复，见缺陷 ⑥⑦。）**

### 4.4 当时的下一步动作（单条主线 + 兜底）

**主线（A）——把诊断改成只输出 5 个关键键值**
不再走 `find` + `PlistBuddy -c 'Print'` 全量打印，改为逐个 `Print :KEY`，并对 `DayEchoWatch.app` **只取 `Release-iphoneos` 下嵌在 `DayEcho.app/PlugIns/` 里的那一份**（当前 `find` 会同时命中 `Release-watchos/` 下的裸产物，存在取错对象的可能）。

一次性拿到：
```
watch app CFBundleIdentifier  = ?
watch app WKWatchOnly         = ?   (应为空)
watch app WKCompanionAppBundleIdentifier = ?
extension WKAppBundleIdentifier = ?
extension NSExtension.NSExtensionPointIdentifier = ?
```

**兜底（B）——改用 Xcode 26 的单一 target 新架构**
把 watch app 从「`watch2_app` 壳 + 独立 `watchkit2-extension`」改为 **SwiftUI watchOS App 直接编译源码、无 extension target**，彻底绕开这套嵌入校验。
代价：改动面较大，`DayEchoWatchExtension` target 与 `DayEchoKitWatch` 的边界需要重划。

**并行（C）——交付文档**
把本文档整理进 `README.md` 的「构建踩坑记录」章节，不再等 CI。

**（已完成 —— 见第五章「工程防线」与 `README.md`。）**

---

## 五、本轮沉淀的工程防线

CI 中新增的两道本地审计（`Sources/ApiAudit/main.swift`），均已做**破坏性验证**：

| 审计 | 拦截的问题 | 破坏性验证 |
|------|-----------|-----------|
| 跨模块 public API 可见性 | `public struct` 缺 `public init()` | 移除 → 立即报错；恢复 → 归零 |
| 32 位 Int 常量溢出 | watchOS `arm64_32` 下 32 位 `Int` 溢出 | 改回乘法表达式 → 报出 `Models.swift:101` + 警告；恢复 → 归零 |

### 5.1 CI 产物校验断言（防止已修复项回归）

**A. 静态防回退断言**（`Assert Embed Watch Content phase is not a silent no-op`，工程生成后立刻跑）

直接对落盘的 `DayEcho.xcodeproj/project.pbxproj` 文本做三判据检查：
- `dstPath = "$(CONTENTS_FOLDER_PATH)/Watch"` 存在
- `dstSubfolderSpec = 16;`
- `DayEchoWatch.app` 的 `PBXBuildFile` 带 `settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }`

> 为什么必须静态查：缺 `dstPath` 时 Xcode **不报错**，整个 copy phase 静默空转。
> 有了这条，不必等 archive 之后才发现产物少 `Watch/` 目录。
> **已做正/负向验证**：正常 pbxproj → 三判据全 PASS；人工删除 `dstPath` → 断言正确报错。

**B. 拷贝落盘硬断言**（`Assert Watch App was copied into host bundle (post-build)`，device build 之后立刻跑）

- `Release-iphoneos/DayEcho.app/Watch/DayEchoWatch.app` 真实存在
- 可执行文件存在且 `lipo -info` 含 `arm64`
- 打印全部判据键值：`CFBundleIdentifier` / `WKCompanionAppBundleIdentifier` / `WKApplication` / `WKWatchOnly` / `WKRunsIndependentlyOfCompanionApp`

**C. archive 后校验**（`Verify watchOS app is embedded`）

- `DayEcho.app/Watch/DayEchoWatch.app` 存在
- watch 二进制为 arm64
- `WKApplication` 存在
- `WKCompanionAppBundleIdentifier` == 宿主 `CFBundleIdentifier`
- watch app **不得**声明 `WKWatchOnly=true`

**D. 打包前断言**（`Pre-Package Assertion (bundle id hierarchy)`）
bundle id 层级校验：宿主 `com.dayecho.app` < watch `com.dayecho.app.watchkitapp`。

**E. 设备二进制校验**（`Verify device binary is arm64`）
为 arm64 且**不含** `x86_64`/`i386-simulator` 模拟器架构。

本地核心测试：`swift run DayEchoTestRunner` → **20/20 全绿**。

---

## 六、工程结构备忘（4 个 target，现代单 target watch 布局）

| target | 类型 | 说明 |
|--------|------|------|
| `DayEcho` | iOS App | 主机身 App（`com.apple.product-type.application`） |
| `DayEchoKit` | iOS Framework | 共享核心逻辑 |
| `DayEchoWatch` | watchOS App | **现代单 target**：直接编译 `Sources/DayEchoWatchApp` 源码，承载 SwiftUI `@main` 入口 |
| `DayEchoKitWatch` | watchOS Framework | watchOS 专用核心逻辑 |

> ✅ **已删除 `DayEchoWatchExtension` target**（旧版 watchapp2 壳 + watchkit2-extension 布局的遗留）。
> 旧的 `legal/WatchExtension-Info.plist` 同步删除。

**嵌入关系**：

```
DayEcho.app/
└── Watch/
    └── DayEchoWatch.app     ← 由 "Embed Watch Content" phase 拷入
                              （dstSubfolderSpec = 16 + dstPath = "$(CONTENTS_FOLDER_PATH)/Watch)"）
```

> ⚠️ 现代单 target 布局下**没有 `PlugIns/` 目录、没有 `.appex`**。
> 旧版 watchapp2 布局才是 `DayEcho.app/PlugIns/DayEchoWatch.app/PlugIns/*.appex`。

Bundle ID 单一来源（`legal/gen_xcodeproj.rb`）：
```ruby
BUNDLE_ID       = 'com.dayecho.app'
WATCH_BUNDLE_ID = 'com.dayecho.app.watchkitapp'
# watch kit : com.dayecho.kit.watch
```

watch App 关键 Info.plist 键（由 build settings 生成）：

| 键 | 值 | 含义 |
|----|-----|------|
| `WKApplication` | `YES` | 现代 SwiftUI watch App 标记 |
| `WKCompanionAppBundleIdentifier` | `com.dayecho.app` | 反向绑定宿主 iOS App |
| `WKRunsIndependentlyOfCompanionApp` | `NO` | 依附式（非独立手表 App） |
| `WKWatchOnly` | **不设** | 一旦为 `true` 即表示独立手表 App，与嵌入模式互斥 |

---

## 七、任务清单状态

| # | 任务 | 状态 |
|---|------|------|
| 6 | Xcode 工程生成脚本 + 双 target 本地化(en/zh-Hans) + 图标 | ✅ 完成 |
| 7 | CI：iOS + watchOS 真机构建并出 `.ipa` | ✅ **完成**（run `43236911252` 双 runner 全绿，`.ipa` 92,468 / 92,537 B） |
| 8 | 交付文档（Auday 差异对照、数据安全设计、已知风险） | 🔶 README 有初版，待按本文档校对 + 补 `.ipa` 交付说明 |
| 9 | REA 逆向实测（验证能否分析 iOS App） | ✅ 已完成：`inspect-macho` 成功解析自产 Mach-O，还原出源码级 Swift 签名，确认 `encryption.status=absent` |
| 10 | 推送 GitHub 仓库 + CI 全绿 | ✅ **完成**（提交 `4090a2e`） |

---

## 八、给后续接手者的注意事项

1. **不要在本地 macOS 上判断 watchOS 真机代码是否正确**。本机 64 位 `Int`，永远测不出 32 位溢出。所有 watch 设备相关的数值上限必须按 `Int64` 设计。
2. **`INFOPLIST_KEY_*` 无法表达嵌套字典**。`NSExtension` 这类结构必须用真实 plist 文件。
3. **watch app 嵌入 iOS App 时，绝不能声明 `WKWatchOnly=true`**——那表示独立手表 App，与嵌入模式互斥。
4. **生成 copy phase 时，`dstPath` 必须手写**。xcodeproj 的 `symbol_dst_subfolder_spec` 只写 `dstSubfolderSpec`，不会补 `dstPath`。缺 `dstPath` 时 Xcode **不报错**，直接把整个 phase 当空操作跳过 —— 症状只是产物少个目录，极难定位。
5. **改完 pbxproj 必须做「正向 + 负向」双验证**：正向确认三判据齐全，负向人工破坏一个字段确认断言能抓到。否则防回退断言本身可能是错的，等于没加。
6. **排查 Xcode 行为不要靠猜，直接对照真实工程**。`Finb/Bark` 是现代单 target watchOS App 的公开可查样本，逐字比对 pbxproj 一次定位根因，比十轮猜测都快。
4. **报错文本的变化是进度指标**。Xcode 的 `ValidateEmbeddedBinary` 会逐条暴露下一个不满足的判据；错误不变 = 当前修复没打中。
5. **CI 诊断输出容易被日志截断**。打印产物结构时应逐键打印并限定查找路径，避免 `find` 命中多个同名产物取错对象。
6. 本机只有 Command Line Tools，**没有完整 Xcode / watchOS SDK**，任何需要 watchOS SDK 的验证都必须走 GitHub Actions。
