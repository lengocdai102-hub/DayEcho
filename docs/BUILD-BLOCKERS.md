# DayEcho 构建卡点详细文档

- **日期**：2026-11-12
- **仓库**：`lengocdai102-hub/DayEcho`（私有）
- **本地路径**：`/Users/maike/Desktop/DayEcho`
- **文档状态**：卡点仍在处理中，本文档记录**截至最后一次 CI run `43224778810` 的真实状态**

---

## 一、一句话结论

CI 前 11 个步骤全部绿灯，唯一失败点是 **`Build for device (arm64, unsigned)`**，报错为：

```
error: WatchKit App doesn't contain any WatchKit Extensions whose
WKAppBundleIdentifier matches "com.dayecho.app.watchkitapp".
Verify that the value of WKAppBundleIdentifier in your WatchKit Extension's
Info.plist matches the value of CFBundleIdentifier in your WatchKit App's Info.plist.
```

**模拟器构建（iOS + watchOS）已全绿**，真机设备构建的 watch 嵌入校验**尚未通过**，因此 **unsigned `.ipa` 尚未产出**。

---

## 二、CI 流水线全貌

### 2.1 步骤级状态（run `43224778810`）

| # | 步骤 | 结果 |
|---|------|------|
| 1 | Set up job | ✅ |
| 2 | Checkout | ✅ |
| 3 | Select latest stable Xcode | ✅ |
| 4 | Show toolchain | ✅ |
| 5 | Run unit tests | ✅ 20/20 |
| 6 | Check localization keys | ✅ |
| 7 | Audit public API cross-module visibility | ✅ |
| 8 | Check Swift syntax | ✅ |
| 9 | Generate Xcode project | ✅ |
| 10 | Build iOS app (simulator) | ✅ |
| 11 | Typecheck watchOS extension | ✅ |
| 12 | Build watchOS app (simulator) | ✅ |
| 13 | **Build for device (arm64, unsigned)** | ❌ **卡在这里** |
| 14 | Dump watch bundle structure | ✅（诊断步骤，`if: always`） |
| 15 | Archive for device and package unsigned `.ipa` | ⏭️ skipped |
| 16 | Verify device binary is arm64 | ⏭️ skipped |
| 17 | Verify watchOS app is embedded | ⏭️ skipped |
| 18 | Collect/Upload artifacts | ✅ |

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

> ⚠️ 报错文本的**变化本身是证据链**：每次修复都推进了 Xcode 的校验进度，直到最后一条不再变化，说明剩余判据尚未被满足。

---

## 三、已修复的 5 个真实缺陷（附证据）

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

## 四、当前唯一未解卡点

### 4.1 报错（run `43224778810`，提交 `f49b55a`）

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

### 4.3 关键缺口

**watch app 产物 `Info.plist` 里的 `CFBundleIdentifier` 实际值尚未取到。**

诊断脚本虽然打印了 watch app 的 Info.plist 全量内容（`CFBundleName = DayEchoWatch`、`WKCompanionAppBundleIdentifier`、`CFBundlePackageType = APPL` 等均在输出中可见），但 `CFBundleIdentifier` 那一行**没有出现在可见输出里**，且本轮 run 的诊断输出在读取环节被日志截断。

两种可能性尚未区分：
1. watch app 产物里的 `CFBundleIdentifier` ≠ `com.dayecho.app.watchkitapp`（例如 `$(PRODUCT_BUNDLE_IDENTIFIER)` 在壳 target 上展开成了别的值，或生成脚本给壳设置的 bundle id 与 extension 的 `WKAppBundleIdentifier` 不同源）；
2. `WKWatchOnly` 虽然从脚本移除，但**该 run 的产物是移除前/后未确认**（提交 `f49b55a` 与 run `43224778810` 的对应关系需再核），产物里仍带 `WKWatchOnly=true`。

**在拿到这个事实之前，不应再做任何猜测性改动。**

### 4.4 下一步动作（单条主线 + 兜底）

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

---

## 五、本轮沉淀的工程防线

CI 中新增的两道本地审计（`Sources/ApiAudit/main.swift`），均已做**破坏性验证**：

| 审计 | 拦截的问题 | 破坏性验证 |
|------|-----------|-----------|
| 跨模块 public API 可见性 | `public struct` 缺 `public init()` | 移除 → 立即报错；恢复 → 归零 |
| 32 位 Int 常量溢出 | watchOS `arm64_32` 下 32 位 `Int` 溢出 | 改回乘法表达式 → 报出 `Models.swift:101` + 警告；恢复 → 归零 |

CI 产物校验新增断言（防止已修复项回归）：
- `DayEchoWatch.app/PlugIns/*.appex` 存在
- `NSExtension:NSExtensionPointIdentifier == com.apple.watchkit`
- `WKAppBundleIdentifier == watch app 的 CFBundleIdentifier`
- watch app **不得**声明 `WKWatchOnly=true`
- 设备二进制为 arm64 且非 fat

本地核心测试：`swift run DayEchoTestRunner` → **20/20 全绿**。

---

## 六、工程结构备忘（5 个 target）

| target | 类型 | 说明 |
|--------|------|------|
| `DayEcho` | iOS App | 主机身 App |
| `DayEchoKit` | iOS Framework | 共享核心逻辑 |
| `DayEchoWatch` | watchOS App（壳） | 嵌入 iOS App 的 `PlugIns/`，**无源码** |
| `DayEchoKitWatch` | watchOS Framework | watchOS 专用核心逻辑 |
| `DayEchoWatchExtension` | watchOS App Extension | 实际承载 SwiftUI `@main` 入口与业务 |

Bundle ID 单一来源（`legal/gen_xcodeproj.rb`）：
```ruby
BUNDLE_ID      = 'com.dayecho.app'
WATCH_BUNDLE_ID = 'com.dayecho.app.watchkitapp'
# extension: #{WATCH_BUNDLE_ID}.extension
# watch kit : com.dayecho.kit.watch
```

---

## 七、任务清单状态

| # | 任务 | 状态 |
|---|------|------|
| 6 | Xcode 工程生成脚本 + 双 target 本地化(en/zh-Hans) + 图标 | ✅ 基本完成 |
| 7 | CI：iOS + watchOS 真机构建并出 `.ipa` | 🔴 卡在 watch 嵌入校验 |
| 8 | 交付文档（Auday 差异对照、数据安全设计、已知风险） | ⬜ README 有初版，未按本文档校对 |
| 9 | REA 逆向实测（验证能否分析 iOS App） | ✅ 已完成：`inspect-macho` 成功解析自产 Mach-O，还原出源码级 Swift 签名，确认 `encryption.status=absent` |
| 10 | 推送 GitHub 仓库 + CI 全绿 | 🔴 仓库已推送，CI 未全绿 |

---

## 八、给后续接手者的注意事项

1. **不要在本地 macOS 上判断 watchOS 真机代码是否正确**。本机 64 位 `Int`，永远测不出 32 位溢出。所有 watch 设备相关的数值上限必须按 `Int64` 设计。
2. **`INFOPLIST_KEY_*` 无法表达嵌套字典**。`NSExtension` 这类结构必须用真实 plist 文件。
3. **watch app 嵌入 iOS App 时，绝不能声明 `WKWatchOnly=true`**——那表示独立手表 App，与嵌入模式互斥。
4. **报错文本的变化是进度指标**。Xcode 的 `ValidateEmbeddedBinary` 会逐条暴露下一个不满足的判据；错误不变 = 当前修复没打中。
5. **CI 诊断输出容易被日志截断**。打印产物结构时应逐键打印并限定查找路径，避免 `find` 命中多个同名产物取错对象。
6. 本机只有 Command Line Tools，**没有完整 Xcode / watchOS SDK**，任何需要 watchOS SDK 的验证都必须走 GitHub Actions。
