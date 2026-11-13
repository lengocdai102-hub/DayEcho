# DayEcho

**Apple Watch 全天候录音 · 你的声音，一个字节都不丢**

> No account. No server. No tracking. Your recordings never leave your devices.

---

## 这是什么

一个 Apple Watch 全天录音 App 的试验品（**试水版**）：在手表上持续录音，分段同步到 iPhone，
本机转写与检索，随时可导出备份。

灵感来自 App Store 上的 **Auday - All-Day Watch Recorder**，但**刻意不复制它的两个致命设计**。

---

## 为什么不是照抄 Auday

调研 Auday 时我读了中美区 127 条评论和它的官方 FAQ。它的两条公开缺陷，
恰好是这类产品最容易踩、也最致命的：

### 缺陷一：同步失败 = 数据永久丢失

Auday 国区/美区差评反复出现同一个故障：几十上百小时的录音卡在「待同步」，
官方给的处理建议是「**删掉 Watch 上的 App 重装**」—— 未同步的录音全部随之消失。
有用户直接定性为「重大产品事故」。

更糟的是它官方 FAQ 里这句话：

> Auday has no server copy of your archive, and the archive is **excluded from iCloud and
> computer device backups**. Do not rely on reinstalling the app or restoring a device
> backup to bring it back.

即：**档案不进 iCloud、不进设备备份、换手机 = 永久丢失**，且没有任何恢复路径。

### 缺陷二：App Store 标了中文，实际没有中文界面

`Chinese` 本地化标签为空，中美区都有用户为此打 1 星。国区用户尤其愤怒。

---

## DayEcho 的两个反向设计

### 1. 失败不丢：分段 + 校验 + 永不删

| Auday | DayEcho |
|---|---|
| 整场录音是一个大文件 | 每 60 秒封一段，独立落盘、独立校验 |
| 同步失败 → 删 App 重装 | 失败段**保留在 Watch 上**，下一轮自动重试 |
| 无校验 | 每段带 SHA-256，手机收到重算比对，坏的不会被当成好的 |
| 官方建议删数据 | **我们永不删未传输/损坏的段** —— 宁可占满存储也不丢 |
| 一次失败可能丢几小时 | 一次失败最多丢几秒 |

核心不变量写在测试里（`DayEchoKitTests.swift`）：

```swift
// 连续多次失败仍不丢（模拟 Auday 的卡死场景）
q.markInFlight(e.id)
q.markFailed(e.id, error: "同步失败")
// …重复 10 次后…
try checkEqual(q.allEntries.count, 1, "10 次失败后数据仍必须存在")
```

### 2. 数据在自己的备份范围内

- 录音存在 iOS 沙盒 `Documents/Recordings`，**处于系统备份范围内** → 换机可恢复
- 一键「导出全部录音」→ 得到含音频与索引的标准目录，自行存入 iCloud Drive / 硬盘 / 任意网盘
- 首页第一屏就是**完整性体检**：段数、占用、缺失文件、校验不符、序列缺口，一眼看清

### 3. 中文是第一等公民

`en` / `zh-Hans` 双语，CI 里跑 `L10nCheck` 强制两语言键集合完全一致。
不存在「标了中文但没做」的情况。

---

## 功能

### Apple Watch

- 一键开始/停止录音
- 计时显示
- 录音中打「标记点」
- **分段落盘**：每段独立写入，写完即入待传队列
- 手表重启/没电，已封段仍在
- 待传计数实时显示

### iPhone

- **备份体检**：逐段校验文件存在性、大小、SHA-256、序列号连续性
- 录音时间线：按会话分组，显示段数与标记数
- 导出全部录音为标准目录 + 索引
- 占用空间统计

---

## 架构

```
Sources/
  DayEchoKit/          # 核心：数据模型、原子存储、传输状态机（无 UI 依赖）
  DayEchoApp/          # iOS SwiftUI 界面 + 本地化 (en / zh-Hans)
  DayEchoWatchApp/     # watchOS 界面 + 录音协调器
  DayEchoCLI/          # 命令行入口（对任意目录跑完整性体检）
  DayEchoTestRunner/   # 自研测试 runner（本机无 Xcode → 无 XCTest）
  L10nCheck/           # 本地化键一致性检查
legal/
  gen_xcodeproj.rb     # 生成 Xcode 工程（iOS + watchOS + Kit framework）
  make_icon.swift      # 生成 1024 图标
  privacy_policy.html  # 隐私政策
```

**关键约束：`DayEchoKit` 必须是真正的 framework target。**
把 Kit 源码混编进 App target 会让 `import DayEchoKit` 报
`no such module 'DayEchoKit'`，而 **SwiftPM 测试会全绿，完全掩盖这个问题** ——
只有真 `xcodebuild` 才暴露。CI 因此同时跑 SwiftPM 测试和真 xcodebuild。

---

## 本地开发

```bash
swift run DayEchoTestRunner    # 核心逻辑测试（20 项）
swift run L10nCheck            # 本地化键一致性
ruby legal/gen_xcodeproj.rb   # 生成 Xcode 工程（需 gem install xcodeproj）
```

## CI

GitHub Actions 在 `macos-15` 单 runner 上构建（2026-11-13 起，原 `macos-15`/`macos-26` 双 runner 已改单 runner）：

> ★ 改单 runner 的原因：GitHub 免费账户 macOS runner 额度按 **10 倍系数**计费，
> 双 runner 每次 run 实扣约 40 分钟额度，跑到第 5–6 次就撞穿上限，
> 且账户未绑支付方式时 job **直接不启动**（报 "recent account payments have failed"，实为额度耗尽）。
> 同时加了 `paths-ignore`（`docs/**`、`research/**`、`*.md`）——
> 纯文档改动不再触发构建，不再消耗额度。


1. SwiftPM 单元测试
2. 本地化检查
3. 跨模块 public API 可见性审计 + 32 位 `Int` 溢出诊断
4. 生成 Xcode 工程
5. **静态防回退断言**：直接检查落盘的 `project.pbxproj` 里 `Embed Watch Content` phase 三判据
6. iOS 模拟器构建
7. **watchOS 模拟器构建**（watchOS API 限制与 iOS 不同，单独编一遍便于定位）
8. iOS 真机 arm64 构建
9. **拷贝落盘硬断言**：`DayEcho.app/Watch/DayEchoWatch.app` 必须真实存在
10. 打包前 bundle id 层级断言
11. 真机归档 → unsigned `.ipa`
12. 验证 device 二进制是纯 arm64（不含模拟器架构）
13. **验证 watchOS App 已正确嵌入 iOS 包**（`Watch/`）

> 模拟器架构装不上真机、也传不上 App Store Connect。
> unsigned `.ipa` 只证明「真机架构下能编译链接通过」，**不能直接安装**。
> 真正装机还需要 Apple Developer 账号、证书与 Provisioning Profile。

### 最新产物（run `43239551136`，提交 `15b4434`）

| 项 | 值 |
|----|-----|
| CI run | `43239551136`（当时为 `macos-15` + `macos-26` 双 runner 全绿，各 23 个成功步骤；此后已改单 runner） |
| 产物 | `DayEcho-unsigned.ipa` |
| 大小 | 92,537 B（macos-15）/ 92,468 B（macos-26，双 runner 时期产物） |
| SHA-256 | `b7aca9cdae8af309b08219ac69f8ed95ba4776a68e4363a02c4f472e6740567c` |
| 本地路径 | `dist/DayEcho-unsigned.ipa` |

**本地解包实测**（不是只看 CI 日志）：

```
Payload/DayEcho.app/
├── DayEcho                      Mach-O 64-bit executable arm64
├── en.lproj/ zh-Hans.lproj/     ✅ 双语资源齐
├── privacy_policy.html
└── Watch/
    └── DayEchoWatch.app/
        ├── DayEchoWatch         Mach-O universal: [arm64_32_v8] [arm64]   ← watchOS 真机架构
        ├── en.lproj/ zh-Hans.lproj/  ✅ 双语资源齐
        └── Info.plist            WKApplication=true
                                 WKCompanionAppBundleIdentifier=com.dayecho.app
                                 WKRunsIndependentlyOfCompanionApp=false
                                 CFBundleIdentifier=com.dayecho.app.watchkitapp
                                 MinimumOSVersion=11.0
```

> ⚠️ **要装到真机还差一步**：需要 Apple Developer 账号 + 证书 + Provisioning Profile，
> 用 Xcode 打开 `DayEcho.xcodeproj` 走签名流程重新 archive。
> 目前的 `.ipa` 是 **unsigned** 的，直接装机会被系统拒绝。

---

## 隐私

- 无账号、无服务器、无登录
- 无广告、无分析、无追踪 SDK
- 不上传录音内容
- Watch → iPhone 直连传输，SHA-256 校验，**不经过任何服务器**
- 数据在系统备份范围内；导出物由用户完全掌控

详见 `legal/privacy_policy.html`。

---

## 当前状态

**试水版。** 核心数据安全逻辑已实现并通过 20 项测试（含针对 Auday 故障场景的不变量测试）。
UI 与 Watch 录音链路为最小可用实现，尚未在真机长时间录音验证过续航与稳定性。

### 已知风险（诚实清单）

- watchOS 后台录音的实际续航表现未在真机验证 —— Auday 的差评里「耗电严重」是主要抱怨之一，
  我们用 60 秒分段换取了抗丢能力，但分段也会增加写入开销，**需要真机实测**。
- WatchConnectivity 的传输时延与中断行为未做真实场景压测。
- 本地转写（Speech framework）尚未接入 —— Auday 的转写与总结也是其差评重灾区，
  这块要单独设计（是否本地、是否允许失败、失败时如何提示）。
- 未做 App Store 上架准备：截图、描述、关键词、审核材料。
- ~~真机设备构建目前未通过 CI~~ → **已解除**：CI run `43236911252` 双 runner 全绿，
  unsigned `.ipa` 已产出（macos-15: 92,468 B / macos-26: 92,537 B）。
- **CI 额度**：免费账户 macOS runner 额度已撞穿过（2026-11-13 用满 193.4 挂钟分 ≈ 1,934 计费分），
  已改单 runner + `paths-ignore` 降低消耗；如需恢复双版本验证，需绑支付方式并设 $5–10 上限。
- **但 unsigned `.ipa` 不能直接安装**：需要 Apple Developer 账号 + 证书 + Provisioning Profile
  走 Xcode 签名流程。本项目**尚未做过真机安装与长时间录音实测**。
  完整根因分析、逐条证据链与修复记录见 **[`docs/BUILD-BLOCKERS.md`](docs/BUILD-BLOCKERS.md)**。

---

## 构建踩坑记录（浓缩版）

完整版见 [`docs/BUILD-BLOCKERS.md`](docs/BUILD-BLOCKERS.md)。四条最值得记住的：

**① watchOS 设备是 32 位指针架构（`arm64_32`），`Int` 只有 2 GiB 上限。**
本机 macOS、iOS 模拟器、iOS 真机全部测不出来 —— 只有 watchOS 真机 Release 构建会炸。
所以 8 GiB 这类默认值必须用 `Int64`：
```swift
// ❌ watchOS 真机必炸：integer literal '8589934592' overflows when stored into 'Int'
public var maxTotalBytes: Int? = 8 * 1024 * 1024 * 1024
// ✅
public var maxTotalBytes: Int64? = 8_589_934_592
```
注意 `Int(8) * 1024 * 1024 * 1024` **也救不了** —— 后续纯字面量仍按 32 位推断。

**② watch 端要用「现代单 target」布局，不是 watchOS 2.0 时代的壳 + extension。**
旧布局（`watchapp2` 壳 + `watchkit2-extension`）配现代 SwiftUI `@main struct App`，
Xcode 的 `embeddedBinaryValidationUtility` 不认它是有效 extension，
报错「doesn't contain any WatchKit Extensions whose WKAppBundleIdentifier matches」。
现代布局是 watchOS App 自己就是 `com.apple.product-type.application`，直接编源码，**没有 extension target**。
嵌入路径也随之变成 `DayEcho.app/Watch/DayEchoWatch.app`（不再是 `PlugIns/*.appex`）。

**③ `PBXCopyFilesBuildPhase` 缺 `dstPath` 会让整个 phase 被静默跳过 —— 最阴的一种。**
xcodeproj 的 `symbol_dst_subfolder_spec = :products_directory` 只写 `dstSubfolderSpec = 16`，
**不会补 `dstPath`**。缺了它 Xcode **不报错**，直接把 "Embed Watch Content" 当空操作跳过，
唯一症状是产出的 `.app` 里没有 `Watch/` 目录：

```ruby
embed_phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'   # ← 必须手写
embed_phase.files.each { |bf| bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] } }
```

CI 里现在有两条断言防它复发：一条静态查 pbxproj 三判据，
一条在 device build 后立刻查 `Watch/DayEchoWatch.app` 是否真实落盘。

> 排查这类 Xcode 行为的通用方法：**别猜，直接对照真实工程的 pbxproj**。
> 公开可查的现代单 target watchOS App 样本：`Finb/Bark`。

为防同类问题复发，CI 里加了两道本地审计（跨模块 public API 可见性、32 位常量溢出），
两道都做过破坏性验证；产物校验也加了对应断言防回归。

---

## 与 Auday 的定位差异

| | Auday | DayEcho |
|---|---|---|
| 定价 | $9.99 / ¥68 买断 | 试水中，定价未定 |
| 服务器 | 无 | 无 |
| 备份 | **明确排除**在 iCloud/设备备份外 | **在**系统备份范围内，可导出 |
| 失败处理 | 官方建议删 App 重装 | 保留待重试，永不删 |
| 完整性 | 无用户可见的校验机制 | 首页体检 + SHA-256 逐段校验 |
| 本地化 | 标了中文但没做 | en/zh-Hans 键集合 CI 强制一致 |
| AI | 自带 API key，云端提供商 | 暂未接入（拟本地优先） |
| 上下文 | 心率/压力/活动/地点/睡眠 | 计划中（同样在系统权限框架内） |

---

## License

Private / All rights reserved.
