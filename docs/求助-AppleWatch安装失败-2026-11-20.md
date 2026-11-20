# 求助：Apple Watch 上安装失败 —— 根因分析请求

> 提交日期：2026-11-20
> 提交方：DayEcho 项目（Swift / SwiftUI，iOS + watchOS 配套 App）
> 目标读者：Gemini（或任何熟悉 Apple 签名与 watchOS 分发的模型）

---

## 一、一句话问题陈述

**iPhone 上主 App 安装成功、启动正常；但配套的 watchOS App 在 Apple Watch 上始终安装失败。**
本项目的怀疑是：导出的 IPA 中，Watch App 使用的 provisioning profile 的 `Platform` 字段是 `iOS` 而不是 `watchOS`，
而**当前开发者账号是免费个人团队（Personal Team），无法签发 watchOS 类型的 provisioning profile**。
请确认这个判断是否成立，以及在免费账号下是否存在任何合法可行的绕过路径。

---

## 二、已确认的事实（全部有机器可验证的实证）

### 2.1 环境

| 项目 | 值 |
|---|---|
| macOS | 15.7.7（Intel Mac，16GB RAM，8 核） |
| Xcode | 26.2，位于 `/Applications/Xcode.app` |
| Team ID | `H98V6YZ5QL` |
| Team Name | `伟 吴` |
| 开发者账号类型 | **免费个人团队（Personal Team）** |
| 账号（侧载签名用） | `551884866@qq.com`（2FA 走 +86 手机号） |
| 实体设备 | iPhone 13 Pro Max (`iPhone14,3`) + Apple Watch Series 12 |
| iOS / watchOS | iOS 26.x / watchOS 26.x |
| 钥匙串中的签名身份 | **仅 1 个**：`D357EDA3F25A7FFC00CE9E58286B9702612BA237` "Apple Development: 551884866@qq.com (4WVTTGB96R)" |
| Apple Distribution 证书 | **不存在**（`security find-certificate -c 'Apple Distribution'` 零命中） |

### 2.2 IPA 包结构（`/tmp/dy_export/DayEcho.ipa`，75 个条目）

包结构**完整且正确**，Watch App 确实被打进 iOS 包内：

```
Payload/DayEcho.app/                                  ← iOS 主 App
Payload/DayEcho.app/PlugIns/DayEchoWidget.appex/      ← iOS Widget
Payload/DayEcho.app/Watch/DayEchoWatch.app/           ← ★ watchOS App（依附式）
Payload/DayEcho.app/Watch/DayEchoWatch.app/PlugIns/DayEchoWatchWidget.appex/  ← watchOS Widget
Payload/DayEcho.app/Watch/DayEchoWatch.app/Frameworks/DayEchoKit.framework/
Payload/DayEcho.app/Frameworks/DayEchoKit.framework/
```

**四个 target 全部带有 `embedded.mobileprovision`**。

### 2.3 ★ 四个 provisioning profile 的实测属性（关键证据）

本机 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 下共 4 个 profile，与 IPA 内嵌的四个一一对应：

| Target | Profile Name | **Platform** | app-id | TTL | 过期时间 |
|---|---|---|---|---|---|
| iOS App | `iOS Team Provisioning Profile: com.dayecho.app.H98V6YZ5QL` | **`iOS`** | `H98V6YZ5QL.com.dayecho.app.H98V6YZ5QL` | 7 | 2026-11-27 |
| iOS Widget | `iOS Team Provisioning Profile: com.dayecho.app.H98V6YZ5QL.widget` | **`iOS`** | `H98V6YZ5QL.com.dayecho.app.H98V6YZ5QL.widget` | 7 | 2026-11-27 |
| Watch App | `iOS Team Provisioning Profile: com.dayecho.app.H98V6YZ5QL.watchkitapp` | **`iOS`** | `H98V6YZ5QL.com.dayecho.app.H98V6YZ5QL.watchkitapp` | 7 | 2026-11-27 |
| Watch Widget | `iOS Team Provisioning Profile: com.dayecho.app.H98V6YZ5QL.watchkitapp.widget` | **`iOS`** | `H98V6YZ5QL.com.dayecho.app.H98V6YZ5QL.watchkitapp.widget` | 7 | 2026-11-27 |

**★ 观察：两个 watchkitapp 的 profile，Platform 也是 `iOS`；本机不存在任何 Platform=watchOS 的 profile（数量 = 0）。**
`TimeToLive = 7` 天 + Profile 名称为 "iOS Team Provisioning Profile" 是免费个人团队的典型特征。

四个 profile 的 `Entitlements` 均含：

```xml
<key>application-identifier</key>  <string>H98V6YZ5QL.com.dayecho.app.H98V6YZ5QL[.watchkitapp[.widget]]</string>
<key>com.apple.developer.team-identifier</key> <string>H98V6YZ5QL</string>
<key>com.apple.security.application-groups</key> <array><string>group.com.dayecho.app.H98V6YZ5QL</string></array>
<key>get-task-allow</key> <true/>
```

每个 profile 的 `ProvisionedDevices` 均为空数组（Xcode 托管的 development profile 常见形态）。

### 2.4 Watch App 的代码签名自洽性（已核验，无问题）

```
$ codesign -d --entitlements - --requirements - Payload/DayEcho.app/Watch/DayEchoWatch.app
designated => identifier "com.dayecho.app.H98V6YZ5QL.watchkitapp"
  and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: 551884866@qq.com (4WVTTGB96R)"
entitlements:
  application-identifier         = H98V6YZ5QL.com.dayecho.app.H98V6YZ5QL.watchkitapp
  com.apple.developer.team-identifier = H98V6YZ5QL
  com.apple.security.application-groups = [group.com.dayecho.app.H98V6YZ5QL]
  get-task-allow = true
```

Info.plist 的依附式三不变量全部正确：

| 键 | 值 | 判定 |
|---|---|---|
| `WKCompanionAppBundleIdentifier` | `com.dayecho.app.H98V6YZ5QL` | ✅ 指向宿主 iOS App |
| `WKApplication` | `true` | ✅ 现代单 target 布局 |
| `WKWatchOnly` | 不存在 | ✅ 依附式（不是独立 Watch App） |

`CFBundleDisplayName` = `DayEcho`。

### 2.5 传输链与配对状态（已排除）

- iPhone 与 Apple Watch **同一 Apple 账号**，已通过 BLE 与 Cloud 完成配对（`WCSession` 激活成功）
- 蓝牙开启，RSSI 约 `-49`
- iPhone 侧 `devicectl` 安装 IPA 返回 `INSTALL_RC=0`，**主 App 在 iPhone 上启动成功并持续存活（PID 9734）**
- 失败的只有 **Watch 端安装**这一步

### 2.6 已排除的其他可能原因

| 假说 | 排除依据 |
|---|---|
| Watch App 没打进 IPA | ✗ 已排除 —— `Payload/DayEcho.app/Watch/DayEchoWatch.app` 存在且结构完整 |
| `WKCompanionAppBundleIdentifier` 配错 | ✗ 已排除 —— 值正确，且不是 App Group 值 |
| 用了旧版 watch2_app/watchkit2-extension 布局 | ✗ 已排除 —— `WKApplication=true`，无 `_WatchKitStub` |
| 证书链不统一（父 App 与内嵌 App 用不同证书） | ✗ 已排除 —— 四个 target 统一为 D357EDA3 同一张证书 |
| 蓝牙 / 配对 / 账号不一致 | ✗ 已排除 —— 见 2.5 |
| entitlements 与 profile 不一致 | ✗ 已排除 —— app-group、app-id 全部一致 |

### 2.7 报错现象

Apple Watch 上安装时失败，宿主侧日志中出现：

```
MIInstallerErrorDomain  Code=111
```

**已知**：这是「profile 不支持该平台 / 缺少对应平台能力」的典型错误码。

---

## 三、本项目的工程配置现状

工程由 `legal/gen_xcodeproj.rb` 生成（Xcodeproj gem），真机签名走 `DAYECHO_DEVICE_SIGNING=1` 开关。

签名配置代码（`legal/gen_xcodeproj.rb` 第 968–1030 行附近）：

```ruby
if DEVICE_SIGNING
  IOS_PROFILE       = "iOS Team Provisioning Profile: com.dayecho.app.#{TEAM_ID}"
  IOS_WIDGET_PROFILE = "iOS Team Provisioning Profile: com.dayecho.app.#{TEAM_ID}.widget"

  apply_signing = lambda do |target, profile|
    target.build_configurations.each do |cfg|
      cfg.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
      cfg.build_settings['DEVELOPMENT_TEAM'] = TEAM_ID
      cfg.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
      cfg.build_settings['CODE_SIGNING_ALLOWED'] = 'YES'
      cfg.build_settings['CODE_SIGNING_REQUIRED'] = 'YES'
      if profile && !AUTO_PROFILE
        cfg.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = profile
      end
    end
  end

  apply_signing.call(ios_target,        IOS_PROFILE)
  apply_signing.call(ios_widget_target, IOS_WIDGET_PROFILE)
  apply_signing.call(kit_target,        nil)   # framework 不支持 profile
  # ★ watchOS 的 profile 尚未签发 ★
  apply_signing.call(watch_target,        nil)
  apply_signing.call(watch_widget_target, nil)
  apply_signing.call(watch_kit_target,    nil)
  apply_signing.call(intents_target,      nil)
end
```

工程注释里已明确写着：

```
# ★ watchOS 的两个 profile 目前尚未签发 ★
# ⇒ watch target 不配 PROVISIONING_PROFILE_SPECIFIER，
#   只配身份与 Team ⇒ 构建能过，真机装机时再补 profile。
```

watchOS target 的平台设置：

```ruby
s['TARGETED_DEVICE_FAMILY'] = '4'
s['SUPPORTED_PLATFORMS']     = 'watchos watchsimulator'
s['SDKROOT']                  = 'auto'   # 现代 watch App 必须用 auto
```

App Group（跨端共享账本）：
```
group.com.dayecho.app.H98V6YZ5QL
```

---

## 四、★ 请回答的问题

### Q1（最关键）诊断是否成立？
> Watch App 的 profile 的 `Platform=iOS`（而非 watchOS），且本机不存在任何 watchOS profile，
> 这是否就是 `MIInstallerErrorDomain Code=111` 的**直接且充分**的原因？
> 还是说 Code=111 另有其他常见成因？

### Q2 免费个人团队的硬限制
> **免费个人团队（Personal Team）是否根本不可能签发 watchOS 类型的 provisioning profile？**
> 我理解个人团队的已知限制包括：profile 有效期 7 天、**没有 Apple Distribution 证书**、
> 设备数上限、App ID 数量上限、**无法创建 App Groups**。
> 请确认：**「无法创建/使用 App Groups」** 这一条对个人团队是否属实？
> 如果属实，那么我们这个 App 因为要跨端共享账本而用了 App Group，
> 在免费账号下**从架构上就不可能**在 Watch 上部署 —— 对吗？

### Q3 是否有合法的免费绕过路径
> 在**不购买付费开发者账号**、**不使用第三方侧载工具**（SideLoadly / iLoader / trollstore 等）、
> 且**必须走 Xcode 官方签名通道**的前提下，是否存在任何路径让 watchOS App 装上实体 Apple Watch？
> 具体想问：
> - 如果在 Xcode 里手动登录同一个免费账号，让 Xcode 自动为 watchOS target 申请 profile，会得到什么？
> - 免费账号下的 watchOS **模拟器**部署能否作为替代交付路径（我们已验证模拟器门禁全绿）？
> - 如果 App Group 是硬阻塞，能否通过**其他共享机制**（如 `WCSession` 传全部数据、
>   `NSUserDefaults(suiteName:)`、或干脆不做跨端共享）让 watchOS App 在免费账号下可部署？

### Q4 如果必须付费
> 付费账号到位后，为了让 iOS App + iOS Widget + Watch App + Watch Widget 全部装上，
> 需要在 Apple Developer 后台创建哪些标识（App ID / App Group）？
> 依赖顺序是什么（先建 App Group 再建 App ID？还是反之）？
> 需要重新 Archive/Export 吗，还是改完 profile 直接重签即可？

### Q5 工程实现层面
> 我们工程用 Xcodeproj gem 生成 `.xcodeproj`（而非手写 project.pbxproj）。
> `watch_target` 与 `watch_widget_target` 目前不设 `PROVISIONING_PROFILE_SPECIFIER`（因为没有 watchOS profile 可指）。
> 在付费账号可用后，需要怎么改才能让 watch target 正确挂上 watchOS profile？
> 需要注意 `watch_kit_target`（watchOS 版 framework）与 `intents_target`（AppIntents extension）是否也需要独立 profile？
> 它们的 bundle id 分别是 `com.dayecho.kit.watch.H98V6YZ5QL` 与 `com.dayecho.app.H98V6YZ5QL.intents`（请确认是否合理）。

---

## 五、附加信息（供参考，可能用得上）

- **模拟器侧全部通过**：watchOS 26.2 模拟器上，Watch App 与 Watch Widget 均可安装、启动、持续存活；
  App Group 容器 `group.com.dayecho.app.H98V6YZ5QL` 在 watchOS 侧独立存在；
  两端 entitlements 一致。跨端门禁脚本 `legal/assert_watch_connectivity_roundtrip.py` 一次跑出 14 passed / 0 fail。
- **App Group 在模拟器上可用** ⇒ 说明 entitlements 本身没问题，问题纯粹在**真机 profile 的平台/账号类型**。
- WatchConnectivity 的 ACK 回传链路目前**尚未接线**（手机端未回发 ACK，Watch 端未实现 `didReceiveUserInfo`），
  这是独立的业务缺口，与本次安装问题无关，但会影响真机联调时的现象解读。

---

## 六、附：本项目的已知取舍

我们**不接受**第三方侧载工具（SideLoadly / iLoader 等）作为交付路径，理由是合规性与可持续性；
我们**接受**「在付费账号不可得期间，用 watchOS 模拟器锁死功能、实体机环节明确标注为未验证」的交付形态。

请重点回答 **Q1 / Q2 / Q3**，这三问决定了我们是否需要立即购买开发者账号，
以及是否需要为免费账号做架构降级（如放弃 App Group）。
