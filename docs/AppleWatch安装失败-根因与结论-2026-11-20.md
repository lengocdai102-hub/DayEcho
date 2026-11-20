# Apple Watch 安装失败 —— 根因分析与结论

> 初稿：2026-11-20 08:00（诊断有误，已修订）
> 修订：2026-11-20 22:00（经外部 AI 复核 + 本机二次取证推翻原诊断）
> 提交方：DayEcho 项目（Swift / SwiftUI，iOS + watchOS 配套 App）

---

## 〇、结论摘要（先看这段）

| 项 | 结论 |
|---|---|
| **现象** | iPhone 上主 App 安装成功、启动正常；**实体 Apple Watch 上 watchOS App 安装失败**，失败码 `MIInstallerErrorDomain Code=111` |
| **根因** | **watchkitapp 的 provisioning profile 的 `ProvisionedDevices` 中不包含 Apple Watch 自身的 UDID** |
| **深层原因** | **免费个人团队（Personal Team）无法在 Apple 官方签名体系下为实体 Apple Watch 签发含其 UDID 的 profile** |
| **可绕过性** | **不可绕过**（在「不付费 + 不用第三方侧载 + 只走 Xcode 官方通道」三重约束下） |
| **代码/工程是否有问题** | **否**。模拟器侧 Watch App / Watch Widget / App Group / entitlements 全部通过（门禁 14 passed / 0 fail） |
| **唯一合规解** | 升级付费 Apple Developer Program |

> ⚠️ 本文记录了**一次被推翻的诊断**（见 §四）。保留它是因为错误的归因会让人在错误方向上反复投入。

---

## 一、环境

| 项目 | 值 |
|---|---|
| macOS | 15.7.7（Intel Mac，16GB RAM，8 核） |
| Xcode | 26.2，`/Applications/Xcode.app` |
| Team ID | `H98V6YZ5QL` |
| Team Name | `伟 吴` |
| 开发者账号类型 | **免费个人团队（Personal Team）** |
| 侧载签名用账号 | `551884866@qq.com`（2FA 走 +86 手机号） |
| 实体设备 | iPhone 13 Pro Max (`iPhone14,3`) + Apple Watch Series 12 |
| 钥匙串签名身份 | **仅 1 个**：`D357EDA3F25A7FFC00CE9E58286B9702612BA237` "Apple Development: 551884866@qq.com (4WVTTGB96R)" |
| Apple Distribution 证书 | **不存在**（`security find-certificate -c 'Apple Distribution'` 零命中） |

---

## 二、★ 决定性证据

### 2.1 四个 provisioning profile 的实测属性

用 `security cms -D` 权威解包 + `plistlib` 解析
（`~/Library/Developer/Xcode/UserData/Provisioning Profiles/`）：

| Profile（Target） | 创建时间 | Platform | ProvisionedDevices |
|---|---|---|---|
| `...H98V6YZ5QL.widget`（iOS Widget） | 08:15:23 | `['iOS','xrOS','visionOS']` | **2 台**：`00008320-0014E51C1EE0000A`, `00008110-000124E63C03801E` |
| `...H98V6YZ5QL`（iOS 主 App） | 08:24:01 | `['iOS','xrOS','visionOS']` | **2 台**：同上两台 |
| `...H98V6YZ5QL.watchkitapp`（Watch App） | 08:54:16 | `['iOS','xrOS','visionOS']` | **★ 1 台**：`00008320-0014E51C1EE0000A` |
| `...H98V6YZ5QL.watchkitapp.widget`（Watch Widget） | 08:54:20 | `['iOS','xrOS','visionOS']` | **★ 1 台**：`00008320-0014E51C1EE0000A` |

四个 profile 全部：`TimeToLive = 7`、`LocalProvision = true`、含 `com.apple.security.application-groups` = `group.com.dayecho.app.H98V6YZ5QL`。

### 2.2 自洽性论证（为什么那台缺失的设备就是 Watch）

1. iPhone 侧主 App 用 `devicectl` 安装 **成功**（`INSTALL_RC=0`），启动正常并持续存活（PID 9734）
   ⇒ **iPhone 的 UDID 必然已在主 App profile 的 ProvisionedDevices 中**。
2. 主 App 与两个 watchkitapp 的 profile 引用同一 Team、同一批设备。
3. watchkitapp 的 profile 只含 **1 台**，主 App profile 含 **2 台**。
4. **反证**：若那 1 台是 Watch，则 iPhone 的 UDID 不在 watchkitapp profile 内 ⇒ iPhone 侧推送 Watch 内容时同样会被拒 ⇒ 与「iPhone 安装成功」直接矛盾。
5. ⇒ **唯一自洽解**：profile 里那 1 台是 iPhone；`00008110-000124E63C03801E` 只出现在 iOS profile，**未出现在 watchkitapp 的 profile 中**。

### 2.3 佐证：Watch App 自身签名完全自洽

```
$ codesign -d --entitlements - --requirements - Payload/DayEcho.app/Watch/DayEchoWatch.app
designated => identifier "com.dayecho.app.H98V6YZ5QL.watchkitapp"
  and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: 551884866@qq.com (4WVTTGB96R)"
entitlements:
  application-identifier              = H98V6YZ5QL.com.dayecho.app.H98V6YZ5QL.watchkitapp
  com.apple.developer.team-identifier = H98V6YZ5QL
  com.apple.security.application-groups = [group.com.dayecho.app.H98V6YZ5QL]
```

Info.plist 依附式三不变量：

| 键 | 值 | 判定 |
|---|---|---|
| `WKCompanionAppBundleIdentifier` | `com.dayecho.app.H98V6YZ5QL` | ✅ |
| `WKApplication` | `true` | ✅ 现代单 target 布局 |
| `WKWatchOnly` | 不存在 | ✅ 依附式 |

### 2.4 IPA 包结构（75 条目）

```
Payload/DayEcho.app/
├── PlugIns/DayEchoWidget.appex/                      ← iOS Widget
├── Watch/DayEchoWatch.app/                           ← ★ watchOS App
│   ├── PlugIns/DayEchoWatchWidget.appex/             ← watchOS Widget
│   └── Frameworks/DayEchoKit.framework/
└── Frameworks/DayEchoKit.framework/
```

四个 target 全部带 `embedded.mobileprovision`。

### 2.5 已排除的原因

| 假说 | 排除依据 |
|---|---|
| Watch App 没打进 IPA | ✗ `Payload/DayEcho.app/Watch/DayEchoWatch.app` 存在且完整 |
| Watch App 被误放进 `PlugIns/` | ✗ 唯一位置是 `Watch/`；`PlugIns/DayEchoWatchWidget.appex` 是 watchOS Widget 应在之处 |
| `WKCompanionAppBundleIdentifier` 配错 | ✗ 值正确 |
| 旧版 watch2_app 布局 | ✗ `WKApplication=true`，无 `_WatchKitStub` |
| 证书链不统一 | ✗ 四个 target 统一 D357EDA3 |
| 蓝牙 / 配对 / 账号不一致 | ✗ 同账号、已 BLE+Cloud 配对、RSSI `-49`、Watch 与 Mac 同账号 |
| entitlements 与 profile 不一致 | ✗ app-group / app-id 全部一致 |
| **profile 的 Platform 字段不是 watchOS** | ✗ **见 §四，这是被推翻的诊断** |

---

## 三、为什么免费账号绕不过

外部 AI（Gemini）复核确认的机制：

1. **Apple Watch 有独立的设备 UDID**，「已与 iPhone 配对」**不自动**赋予它独立真机安装授权。
2. Profile 必须包含目标 Watch 的 UDID，Watch 侧 MobileInstallation 校验才会通过，否则 `MIInstallerErrorDomain Code=111`。
3. 免费个人团队**无法**在开发者后台完整管理设备与能力，签发不出含 Watch UDID 的 profile。
4. `xcodebuild -allowProvisioningUpdates` 只是触发自动签名/Profile 更新流程，**不能越过账号本身的权限与设备授权上限**。
5. ⇒ **在「不付费 + 不用第三方侧载 + 只走 Xcode 官方通道」下：无解。**

已排除的「假想解法」：
- 调低 deployment target —— 与签名授权无关
- 反复重签同一份免费 profile —— profile 内容不变
- 调整蓝牙 / 配对 —— 与 profile 无关
- 换用 `deliversAcknowledgement` 等代码改动 —— 属业务逻辑，与安装失败无关

---

## 四、★ 被推翻的诊断（保留记录）

### 4.1 当时的错误结论
> 「Watch App 的 profile 的 `Platform = iOS` 而非 `watchOS`，而免费账号无法签发 watchOS profile ⇒ 这是 `Code=111` 的直接且充分的原因。」

### 4.2 错在哪
**解析 bug**：我用正则 `<key>Platform</key>\s*<array>\s*<string>(.*?)</string>`，只取了数组**第一项**，
把 `['iOS','xrOS','visionOS']` 读成了 `['iOS']`。
并且用 `plistlib` 直读含 `DER-Encoded-Profile` 的 profile 时 `ProvisionedDevices` 读出来是空 —— 同样是解析方式问题，
实际用 `security cms -D` 解包后有 1~2 台设备。

### 4.3 外部 AI 的两条指正（已复核）
- ✅ **「Platform 不必含 watchOS」是对的** —— iOS 开发 profile 本就覆盖 watchOS。
- ❌ 它指出的「结构错位」和「拼写错误」**是误读** —— 前者是我贴给它的 Markdown 里压缩过的结构树，
  后者是代码在渲染时被挤成 `apply_signing.call(ios_target, IOS_PROt, IOS_WIDGET_PROFILE)`；
  源码实为 `apply_signing.call(ios_target, IOS_PROFILE)`，无拼写错误。

### 4.4 教训
- ★ **profile 的字段必须用 `security cms -D` 解包后再解析**，不能对原始二进制做正则 —— 数组字段会被截断。
- ★ **`plistlib` 直读 `.mobileprovision` 会因 `DER-Encoded-Profile` 干扰而失真**。
- ★ 「iOS Team Provisioning Profile」这个名字里的 "iOS" **不代表不能用于 watchOS**。

---

## 五、付费账号到位后的执行清单

按依赖顺序：

1. **Apple Developer 后台创建 App Group**：`group.com.dayecho.app.H98V6YZ5QL`
   （iOS 与 watchOS 在同一 Team 下共用同一 App Group 标识符）
2. **创建显式 App ID 并勾选 App Groups Capability**：
   - `com.dayecho.app.H98V6YZ5QL`（主 App）
   - `com.dayecho.app.H98V6YZ5QL.widget`（iOS Widget）
   - `com.dayecho.app.H98V6YZ5QL.watchkitapp`（Watch App）
   - `com.dayecho.app.H98V6YZ5QL.watchkitapp.widget`（Watch Widget）
   - `com.dayecho.app.H98V6YZ5QL.intents`（AppIntents 扩展，独立分发 ⇒ 需独立 profile）
3. **登记 Apple Watch 为设备**（关键一步，免费账号做不到）
4. 生成对应的 Development / Distribution Profile
5. `legal/gen_xcodeproj.rb` 中为 `watch_target` / `watch_widget_target` /
   `intents_target` 填上 `PROVISIONING_PROFILE_SPECIFIER`
6. **重新 Archive 并 Export** —— 必须重新打包，Profile 变了就不能只重签旧 IPA
7. 真机安装与联调

补充说明：
- `watch_kit_target`（watchOS 版 framework）**不需要**独立 profile —— framework 不支持独立 profile，
  由宿主 `DayEchoWatch.app` 嵌入并随宿主签名。
- `intents_target` 若作为独立 `.appex` 参与分发，**需要**独立 profile（带 Capability 的扩展不能用通配符）。

---

## 六、当前的交付边界（诚实声明）

**已验证（模拟器）**
- watchOS 26.2 模拟器：Watch App / Watch Widget 可安装、可启动、持续存活
- watchOS 侧独立 App Group 容器 `group.com.dayecho.app.H98V6YZ5QL` 存在
- 双端 entitlements 一致；依附式三不变量正确
- 跨端生命周期门禁 `legal/assert_watch_connectivity_roundtrip.py`：一次跑出 **14 passed / 1 warn / 0 fail**

**未验证（实体机）**
- **实体 Apple Watch 上安装 watchOS App —— 未成功**（`Code=111`）
- **实体 Watch ↔ iPhone 的真实 segment 传输 —— 未跑通**
- **ACK 闭环 —— 未通**（三处缺口已定位到行号，待修复）

> 模拟器结果**不等价于**实体 Watch 已安装或真机功能已验收。

---

## 七、附：与安装失败无关、但已定位的业务缺口（另案处理）

| 缺口 | 位置 |
|---|---|
| 手机端收到 Watch segment 后**未回发 ACK** | `Sources/DayEchoApp/PhoneReceiveChannel.swift` 的 `session(_:didReceive file:)` |
| Watch 端**未实现 `didReceiveUserInfo`** | `Sources/DayEchoWatchApp/WatchSessionCoordinator.swift:177` |
| `deliversAcknowledgement` 固定为 `false` | `Sources/DayEchoWatchApp/WatchTransferChannel.swift:131` |
| 接收端**无 segment 级幂等去重** | `Sources/DayEchoKit/RecordingStore.swift:105`（`index.segments.append` 无条件追加） |

> ACK 应走独立 `transferUserInfo` 通道（`AcknowledgementKey.metadataKey = "dayecho.ack"`），
> **不应**把 `deliversAcknowledgement` 直接改成 `true`（会绕过真实确认直接标记 `.verified`）。
> 段级去重须发生在写盘前，按 `sessionID + sequence` 判重、`sha256` 校验。
