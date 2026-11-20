#!/usr/bin/env ruby
# 生成 DayEcho 的 Xcode 工程（iOS App + watchOS App + Kit framework）。
# 用法：ruby legal/gen_xcodeproj.rb
#
# 关键点（都是踩过的坑）：
#   1. Kit 必须是真正的 framework target —— 混编进 App 会报
#      "no such module 'DayEchoKit'"，而 SwiftPM 全绿完全掩盖这个问题。
#   2. watchOS App 必须嵌入在 iOS App 里（"Embed Watch Content"），
#      且 watchOS target 是 iOS target 的依赖。
#   3. lproj 必须用 PBXVariantGroup，否则本地化整个失效。
#   4. knownRegions 不登记的 lproj，Xcode 不认这个语言。
require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path(File.join(__dir__, '..'))
PROJ_PATH = File.join(ROOT, 'DayEcho.xcodeproj')

FileUtils.rm_rf(PROJ_PATH)
project = Xcodeproj::Project.new(PROJ_PATH)

IOS_MIN = '17.0'
# watchOS 26 起支持 Control Widget（表盘上真正的一键动作按钮）
# 与 AppIntent.supportedModes（后台执行）。
#
# ★ 为什么从 11 提到 26 ★
#
# 阶段 2.1 核实（Apple 官方 DocC 实测）：
#   - ControlWidgetButton / StaticControlConfiguration → watchOS 26.0
#   - AppIntent.supportedModes / IntentModes        → watchOS 26.0
#
# ★ 为什么必须整体统一，不能只给 extension 提 ★
#
# watchOS 的 Widget Extension 嵌在 watch App 的 PlugIns/ 里，
# extension 的部署目标**不能高于**宿主 app。
# 若 watch App 还是 11 而 widget 是 26 ⇒ 装不上 / 编译报错。
#
# ★ 用户设备兼容性 ★
#
# Apple Watch Series 12 支持 watchOS 26/27 ⇒ 目标用户设备完全覆盖。
# watchOS 11–25 的用户拿不到「表盘一键抓拍」，这是 V1 的已知取舍：
# 宁可让目标用户拿到完整功能，也不要做一个「所有设备都能装，
# 但核心按钮在老系统上点不出来」的半成品。
#
# ★ 降级入口仍保留 ★
#
# watch App 内的界面入口不依赖 Control Widget，
# 老系统用户仍可从 App 内启动抓拍（只是多一步）。
WATCH_MIN = '26.0'
# ★ Bundle ID 必须与 Apple 实际签发的 App ID 完全一致 ★
#
# ★ 2026-11-19 的教训（血泪）★
# Apple 签发的 Team Provisioning Profile 里是：
#   com.dayecho.app.H98V6YZ5QL          (主 App)
#   com.dayecho.app.H98V6YZ5QL.widget   (iOS Widget)
# 而这里原本写的是 'com.dayecho.app'（不带 Team ID 后缀）
# ⇒ 真机上 profile 与 Bundle ID 不匹配 ⇒ 装不上
# ⇒ 当时为了绕过签名手工改了 project.pbxproj，但**生成器没改**
# ⇒ CI 每次重新生成工程都退回错的 ⇒ CI 与本地行为不一致
# ⇒ 并且 WKCompanionAppBundleIdentifier 跟着一起被改错
# ⇒ 模拟器直接拒绝安装：
#    "Invalid value of WKCompanionAppBundleIdentifier key in WatchKit 2.0
#     app's Info.plist: com.dayecho.app.H98V6YZ5QL (expected com.dayecho.app)"
#
# ⇒ 现在所有 Bundle ID 一律从 TEAM_ID 派生，杜绝手改后遗漏。
TEAM_ID = ENV['DAYECHO_TEAM_ID'] || 'H98V6YZ5QL'
BUNDLE_ID = "com.dayecho.app.#{TEAM_ID}"
WATCH_BUNDLE_ID = "#{BUNDLE_ID}.watchkitapp"

# ============================================================
# App Group（跨进程共享容器）—— 默认**关闭**，按需开启
# ============================================================
#
# ★ 为什么默认关闭 ★
#
# App Group 需要**付费开发者账号**（$99/年）才能签名。
# 本项目的验收方式是「unsigned 构建装到用户自己的 iPhone 上跑」，
# 用户用的是**免费 Personal Team**。
#
# 如果默认带上 entitlements：
#   Personal Team 签名时遇到 app-group ⇒ **签名失败**
#   ⇒ 整个 App 装不上 ⇒ V1 直接归零。
#
# ★ 所以必须做成开关 ★
#   - 默认（不设置环境变量）：不挂 entitlements，Personal Team 也能装。
#     SharedContainer 自动回退到 Documents/DayEchoShared。
#   - DAYECHO_APP_GROUP=1：挂上 entitlements，走真正的共享容器。
#     需要付费账号。
#
# ★ 开启方式 ★
#   DAYECHO_APP_GROUP=1 ruby legal/gen_xcodeproj.rb
#
# ★ 回退路径不是降级，是正常路径 ★
# 目录结构、文件名、写入方式在两条路径下完全一致，
# 唯一差别只有落盘位置。测试覆盖的就是这一层。
# ★ 2026-11-19 修正 ★ 默认改为**开启**。
#
# 原注释的理由是"免费 Personal Team 签名时带 app-group 会失败"——
# 但本项目现在用的是**付费 Team（H98V6YZ5QL）**，
# Apple 实际签发的 profile 里就含 App Group
# （group.com.dayecho.app.H98V6YZ5QL），
# entitlements 与 profile 不一致 ⇒ 真机签名/安装直接失败。
#
# ⇒ 模拟器构建也必须挂上 entitlements，
#   否则 CI 验的产物与真机产物根本不是同一个东西。
# ⇒ 保留 DAYECHO_APP_GROUP=0 作为显式关闭开关（仅供无 App Group 的场景调试）。
USE_APP_GROUP = ENV['DAYECHO_APP_GROUP'] != '0'
# ★ App Group（entitlement）与 Bundle ID 是两回事 ★
# App Group 是 'group.' 前缀，值里带 Team ID；Bundle ID 不带 'group.' 前缀。
# ★ 2026-11-19 的教训 ★ 我曾把 App Group 的值误填进
#   WKCompanionAppBundleIdentifier ⇒ 系统拒绝安装。
APP_GROUP_ID = "group.com.dayecho.app.#{TEAM_ID}"

# ============================================================
# 真机（付费开发者账号）签名开关 —— 默认**关闭**
# ============================================================
#
# ★ 为什么需要这个开关 ★
#
# 默认（模拟器/CI 用途）：
#   CODE_SIGNING_ALLOWED = NO、CODE_SIGN_IDENTITY = ""
#   ⇒ 不签名，构建快，且不依赖任何证书
#
# 真机安装（DAYECHO_DEVICE_SIGNING=1）：
#   每个 target 都要**各自**的 provisioning profile：
#     主 App  → iOS Team Provisioning Profile: com.dayecho.app.H98V6YZ5QL
#     Widget  → iOS Team Provisioning Profile: com.dayecho.app.H98V6YZ5QL.widget
#   ⇒ 不能用命令行全局覆盖（全局只给一个值），
#     必须在工程里 per-target 配好。
#
# ★ 踩过的坑 ★
# 2026-11-20 真机构建时只传了命令行参数：
#   DEVELOPMENT_TEAM / CODE_SIGN_STYLE=Manual / PROVISIONING_PROFILE_SPECIFIER
# 结果 **BUILD SUCCEEDED 但产物没签名**：
#   warning: DayEcho isn't code signed but requires entitlements.
# 根因：工程的 CODE_SIGN_IDENTITY = "" + CODE_SIGNING_ALLOWED = NO
#       ⇒ Xcode 判定「没有可用身份」⇒ 直接跳过签名，不报错。
# ⇒ "编译成功"≠"签名成功"，这是第 4 种「静默失效」的同款陷阱。
#
# ★ 开启方式 ★
#   DAYECHO_DEVICE_SIGNING=1 ruby legal/gen_xcodeproj.rb
DEVICE_SIGNING = ENV['DAYECHO_DEVICE_SIGNING'] == '1'
AUTO_PROFILE  = ENV['DAYECHO_AUTO_PROFILE'] == '1'


# ============================================================
# 1. iOS App target
# ============================================================
ios_target = project.new_target(:application, 'DayEcho', :ios, IOS_MIN)

# ============================================================
# 2. Kit framework target
# ============================================================
kit_target = project.new_target(:framework, 'DayEchoKit', :ios, IOS_MIN)
kit_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "com.dayecho.kit.#{TEAM_ID}"
  s['PRODUCT_NAME'] = 'DayEchoKit'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  s['DEFINES_MODULE'] = 'YES'
  s['SKIP_INSTALL'] = 'YES'
  s['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'NO'
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'NO'
  # Kit 用到的框架
  s['FRAMEWORK_SEARCH_PATHS'] = '$(inherited)'
end

# Kit 源码
#
# ★ 用 glob 自动收集，不要手写枚举 ★
#
# 手写枚举时踩过的坑：新增了 RecordingSealer.swift / SegmentClock.swift /
# TransferCoordinator.swift / Acknowledgement.swift 四个文件，
# 但忘记把它们加进这个列表 ⇒
#   - SwiftPM 全绿（SwiftPM 自己会 glob）
#   - Xcode 工程里 DayEchoKit framework **缺这几个文件**
#   - 编译 watchOS app 时报 `cannot find type 'RecordingSealer' in scope`
#
# ★ 为什么 SwiftPM 全绿掩盖了这个问题 ★
# SwiftPM 编译 DayEchoKit 时会 glob 全部源文件，所以本机 `swift build` 和
# CI 的 `swift run DayEchoTestRunner` 都是绿的；
# 但 Xcode 工程是独立生成的，它用的是上面这份**手写清单**。
# 两套构建系统的源文件列表不一致 ⇒ 只有真机编译阶段才炸。
#
# 改成 glob 之后，新增文件自动进两个 Kit target（iOS + watchOS），
# 不会再出现这种「本机绿、CI 红」的错配。
kit_files = Dir.glob(File.join(ROOT, 'Sources/DayEchoKit/**/*.swift'))
             .map { |p| p.sub("#{ROOT}/", '') }
             .sort
raise '★ DayEchoKit 源文件为空 —— glob 失败？' if kit_files.empty?
kit_group = project.new_group('DayEchoKit', 'Sources/DayEchoKit')
kit_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = kit_group.new_reference(File.basename(f))
  kit_target.add_file_references([ref])
end

# ============================================================
# 3. watchOS App（现代单 target 布局）
# ============================================================
# watchOS 有两种工程布局：
#   旧版  watch2_app (壳) + watchkit2-extension (业务)  —— 本项目已弃用
#   现代  watchOS App 单 target，直接编 Swift 源码        —— 本项目采用
#
# ★ 为什么弃用旧版 ★
# 旧版要求 extension 带 NSExtensionPrincipalClass（WKExtensionDelegate 子类），
# 而业务代码用的是现代 SwiftUI 生命周期（@main struct App），不该有 principal class。
# 结果 appex 位置对、plist 键值全对，Xcode 的 embeddedBinaryValidationUtility
# 却一律报 "WatchKit App doesn't contain any WatchKit Extensions whose
# WKAppBundleIdentifier matches ..."。
#
# ★ 三个佐证 ★
#   1) watch app 的 WKApplication = <NOT_SET>（现代 watch App 才有这个键）
#   2) 产物里有 _WatchKitStub/WK（旧版 watchapp2 的标记）
#   3) watch app 的 plist 用 -producttype com.apple.product-type.application.watchapp2 生成
#
# 现代布局下没有 extension、没有 PlugIns、没有 WatchKit 嵌入校验，
# iOS App 通过 "Embed Watch Content"（dst = :watch）把手表 App 放进 Watch/ 目录。

# ---- 3a0. watchOS 版 DayEchoKit ----
# 同一个 framework target 不能同时产 iOS 与 watchOS 版本（平台不同、
# 头文件不同）。watchOS extension 必须链接 watchOS 架构的 Kit，
# 否则链接期报 "building for iOS but linking in watchOS framework"。
watch_kit_target = project.new_target(:framework, 'DayEchoKitWatch', :watchos, WATCH_MIN)
watch_kit_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "com.dayecho.kit.watch.#{TEAM_ID}"
  s['PRODUCT_NAME'] = 'DayEchoKit'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['WATCHOS_DEPLOYMENT_TARGET'] = WATCH_MIN
  s['TARGETED_DEVICE_FAMILY'] = '4'
  s['SUPPORTED_PLATFORMS'] = 'watchos watchsimulator'
  s['SDKROOT'] = 'watchos'
  s['DEFINES_MODULE'] = 'YES'
  s['SKIP_INSTALL'] = 'YES'
  s['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'NO'
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
end

watch_kit_group = project.new_group('DayEchoKitWatch', 'Sources/DayEchoKit')
kit_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = watch_kit_group.new_reference(File.basename(f))
  watch_kit_target.add_file_references([ref])
end

# ---- 3. watchOS App（现代单 target 布局）----
#
# ★★ 布局决策：为什么不用「watch2_app 壳 + watchkit2-extension」★★
#
# 旧布局（watchapp2 + watchkit2-extension）下，Xcode 的校验命令是：
#   embeddedBinaryValidationUtility #     .../DayEchoWatch.app/PlugIns/DayEchoWatchExtension.appex #     -info-plist-path .../DayEchoWatch.app/Info.plist
#
# 这个工具要求 extension 有 NSExtensionPrincipalClass（WKExtensionDelegate 子类），
# 才承认它是有效的 WatchKit Extension。而我们的业务代码用的是
# 现代 SwiftUI 生命周期（@main struct DayEchoWatchApp: App），
# 放在 extension 里根本不该有 principal class。
#
# 结果：appex 在磁盘上位置正确、plist 键值全部正确
#   ext  WKAppBundleIdentifier      = com.dayecho.app.watchkitapp  ✓
#   ext  NSExtensionPointIdentifier = com.apple.watchkit           ✓
#   watch CFBundleIdentifier        = com.dayecho.app.watchkitapp  ✓
# 但校验工具一律报：
#   error: WatchKit App doesn't contain any WatchKit Extensions whose
#   WKAppBundleIdentifier matches "..."
#
# ★ 三个佐证指向同一结论：
#   1) watch app 的 Info.plist 里 WKApplication = <NOT_SET>
#      —— WKApplication 是现代 SwiftUI watch App 的标记键
#   2) 产物里有 _WatchKitStub/WK —— 旧版 watchapp2 的标记，
#      现代 watch app 不该有
#   3) watch app 的 plist 用 -producttype com.apple.product-type.application.watchapp2 生成
#
# ★ 解决方案：改用 Xcode 14+ 的现代单 target 布局。
#   watchOS App 自己就是 com.apple.product-type.application，
#   直接编译 Swift 源码，没有 extension，没有 PlugIns，
#   iOS App 通过 "Embed Watch Content" 把它放进自己的 Watch/ 目录。
#   整套 WatchKit Extension 嵌入校验（ValidateEmbeddedBinary）根本不适用。
watch_target = project.new_target(:application, 'DayEchoWatch', :watchos, WATCH_MIN)
watch_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = WATCH_BUNDLE_ID
  s['PRODUCT_NAME'] = 'DayEchoWatch'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['WATCHOS_DEPLOYMENT_TARGET'] = WATCH_MIN
  s['TARGETED_DEVICE_FAMILY'] = '4'
  s['SUPPORTED_PLATFORMS'] = 'watchos watchsimulator'
  # ★ SDKROOT 必须是 auto，不能硬写成 watchos ★
  #
  # 硬写成 watchos 时，watch target 的产物只落在 Build/Products/Release-watchos/，
  # 而 iOS 宿主的 "Embed Watch Content" copy phase 从 iOS 侧的 products 目录
  # 找不到 DayEchoWatch.app —— Xcode 会**静默跳过**这个 phase，
  # 编译不报错，但产出的 .app 里根本没有 Watch/ 目录，
  # 表现为「iOS 包里没找到嵌入的 DayEchoWatch.app」。
  #
  # 真实 Xcode 工程里 watch app target 用的是 SDKROOT = auto，
  # 这样 Xcode 才能在 iOS 构建时正确产出并嵌入 watch 变体。
  s['SDKROOT'] = 'auto'
  # ★ 用真实的 Info.plist 文件，不用 GENERATE_INFOPLIST_FILE ★
  #
  # ★ 为什么必须用真实文件 ★
  # `INFOPLIST_KEY_UIBackgroundModes` 在 GENERATE_INFOPLIST_FILE=YES 时
  # 会被 Xcode **整体丢弃**（实测 fix4 产物：watch 侧无此键）。
  # 手表侧全天录音靠 `UIBackgroundModes = audio` 保活，
  # 丢了它 ⇒ 锁屏/息屏后录音进程被系统挂起。
  # ⇒ 只有提供真实 Info.plist 文件、在里面写真正的 <array> 才可靠。
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['INFOPLIST_FILE'] = 'Sources/DayEchoWatchApp/Info.plist'
  # ★ framework 的 rpath —— 没有它 dyld 找不到 DayEchoKit.framework ★
  #
  # ★ 两个键都要写 ★
  # LD_RUNPATH_SEARCH_PATHS 是 Xcode 15+ 的新键，优先级高于旧的 LD_RUNPATH。
  # 工程级默认已经带了 LD_RUNPATH_SEARCH_PATHS，
  # 只写 LD_RUNPATH 会被工程级的 SEARCH_PATHS 覆盖，
  # 结果产物里一个 LC_RPATH 都没有（实测 watch 二进制 rpath = <无 LC_RPATH>）。
  s['LD_RUNPATH'] = '$(inherited) @executable_path/Frameworks'
  s['LD_RUNPATH_SEARCH_PATHS'] =
    '$(inherited) @executable_path/Frameworks @loader_path/Frameworks'
  # ★ 显示名 / WKApplication / Companion 指针 / 后台模式 / 权限文案
  #   全部在 Sources/DayEchoWatchApp/Info.plist 里 ★
  #
  # 本 target 用 GENERATE_INFOPLIST_FILE = 'NO',
  # 所以 INFOPLIST_KEY_* 这一整套**完全不生效**（会被 Xcode 忽略）。
  # ⇒ 单一真源 = Sources/DayEchoWatchApp/Info.plist。
  #
  # ★ WKWatchOnly 绝不能出现 ★
  # 那是独立手表 App 的语义，与「嵌入宿主的依附式手表 App」互斥。
  # 显式删除，防止以后有人误加。
  s.delete('INFOPLIST_KEY_WKWatchOnly')
  # ★ 麦克风权限声明（watchOS 必填）在
  #   Sources/DayEchoWatchApp/Info.plist 里 ★
  # 漏掉这条的真实后果：在手表上点「开始录音」会被系统直接拒绝，
  # AVAudioSession 激活失败，而且**没有任何错误提示**——
  # 表现为「按了没反应」。iOS 侧声明了不代表 watch 侧自动继承，
  # 每个 target 都要各自声明自己的权限。
  # ★ 后台音频模式（全天录音的正解）★
  #
  # UIBackgroundModes = audio 是 watchOS 上持续录音的关键：
  # 只要音频录制会话处于激活状态，watchOS 就不会因锁屏/息屏挂起进程，
  # 录音可以持续进行。
  #
  # WKExtendedRuntimeSession 不能替代它 —— 那个 API 有严格的系统时长配额，
  # 是给闹钟/正念/理疗这类短时场景设计的，用来做全天录音会被系统掐断。
  # 这里把 WKExtendedRuntimeSession 当作补充保活手段，UIBackgroundModes 才是主力。
  #
  # ★ 这个值写在 Sources/DayEchoWatchApp/Info.plist 里，不是这里 ★
  # INFOPLIST_KEY_UIBackgroundModes 在 GENERATE_INFOPLIST_FILE=YES 时
  # 会被 Xcode **整体丢弃**（实测 fix4 产物里 watch 侧也没有这个键）。
  # ⇒ Watch App 改用真实 Info.plist 文件（见本 target 的
  #   GENERATE_INFOPLIST_FILE = 'NO' / INFOPLIST_FILE 设置）。
  # ★ watch 图标集名 ★
  #
  # watchOS 的图标集叫 `WatchAppIcon.appiconset`（不是 iOS 的 `AppIcon`）。
  # 不设这个键 ⇒ actool 不会为 watch target 编译任何图标
  # ⇒ 手表桌面上**根本没有图标**（用户报「Watch 上找不到 DayEcho」）。
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'WatchAppIcon'
  # 前台持续显示录音状态（用户能一眼看出在录音）
  # ★ watch app 的 framework rpath ★
  s['LD_RUNPATH'] = '$(inherited) @executable_path/Frameworks'
  s['LD_RUNPATH_SEARCH_PATHS'] =
    '$(inherited) @executable_path/Frameworks @loader_path/Frameworks'
  # INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents 在
  # GENERATE_INFOPLIST_FILE=NO 时被忽略；
  # 如需该键，写进 Sources/DayEchoWatchApp/Info.plist。
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['SKIP_INSTALL'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  # ★ App Group entitlements（默认不挂）★
  # 见文件顶部 USE_APP_GROUP 说明。
  if USE_APP_GROUP
    s['CODE_SIGN_ENTITLEMENTS'] = 'legal/DayEchoWatchApp.entitlements'
  end
end

# watch app 依赖 watchOS 版 Kit
watch_target.add_dependency(watch_kit_target)
watch_target.frameworks_build_phase.add_file_reference(watch_kit_target.product_reference)

# watch app 的业务源码（SwiftUI @main 入口就在这里）
#
# ★ 用 glob 自动收集，不要手写枚举 ★
#
# 理由与 Kit target 一样：
# 手写枚举时新增了 CaptureIntent.swift 却忘记加进来 ⇒
#   - SwiftPM 全绿（Kit 是 SwiftPM target）
#   - Xcode 工程里 DayEchoWatch target 缺这个文件
#   - 编译 watch app 时报 "cannot find type 'StartCaptureIntent' in scope"
#
# 改成 glob 之后，新增文件自动进 target。
watch_files = Dir.glob(File.join(ROOT, 'Sources/DayEchoWatchApp/**/*.swift'))
                .map { |p| p.sub("#{ROOT}/", '') }
                .sort
raise '★ DayEchoWatchApp 源文件为空 —— glob 失败？' if watch_files.empty?
watch_group = project.new_group('DayEchoWatchApp', 'Sources/DayEchoWatchApp')
watch_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = watch_group.new_reference(File.basename(f))
  watch_target.add_file_references([ref])
end

# watch app 的本地化
watch_lproj_group = project.new_group('WatchLocalization', 'Sources/DayEchoWatchApp/WatchResources')
%w[en zh-Hans].each do |lang|
  lproj_path = File.join(ROOT, "Sources/DayEchoWatchApp/WatchResources/#{lang}.lproj")
  next unless File.directory?(lproj_path)
  vg = watch_lproj_group.new_variant_group("#{lang}.lproj")
  vg.new_reference(File.join(lproj_path, 'Localizable.strings'))
  watch_target.add_resources([vg])
end

# ============================================================
# 4. iOS App 依赖与嵌入
# ============================================================
ios_target.add_dependency(kit_target)
ios_target.frameworks_build_phase.add_file_reference(kit_target.product_reference)

# ★★★ "Embed Frameworks" 阶段 —— 缺了它，App 启动即崩 ★★★
#
# ★ 症状 ★
# 装到 iPhone 上，图标点开闪退，什么都看不到。
#
# ★ 根因（硬证据）★
# 主二进制 DayEcho 链接的是 @rpath/DayEchoKit.framework/DayEchoKit，
# 而它的 LC_RPATH 是 @executable_path/Frameworks
# ⇒ dyld 会在 DayEcho.app/Frameworks/ 里找 DayEchoKit.framework。
#
# 但 xcode 工程里**从来没有 "Embed Frameworks" 构建阶段**
# （只有 "Embed Watch Content" 和 "Embed Widget Extensions"），
# ⇒ DayEchoKit.framework 只被「链接」，从没被「拷贝」进 .app
# ⇒ DayEcho.app/Frameworks/ 目录根本不存在
# ⇒ dyld 找不到库 ⇒ 启动即被系统杀掉（表现为闪退）。
#
# ★ 为什么编译期不报错 ★
# 链接期只需要 framework 的二进制，不需要它出现在产物包里。
# 缺 Embed 阶段是**打包期**问题，编译/链接全程无感。
# 这就是为什么 CI 全绿、真机却起不来。
#
# ★ 为什么之前没被发现 ★
# CI 的校验只查了 Watch/ 目录和 PlugIns/ 目录，
# 从来没查过 Frameworks/ 目录，也没人跑过 otool -L 看 rpath 依赖。
#
# ★ 参考真实 Xcode 工程 ★
# Xcode 自己生成的工程里，App target 一定有一个 "Embed Frameworks"
# 阶段，dstSubfolderSpec = 10（frameworks），dst_path = ""，
# build file 带 ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy)。
embed_frameworks = ios_target.new_copy_files_build_phase('Embed Frameworks')
embed_frameworks.symbol_dst_subfolder_spec = :frameworks
embed_frameworks.dst_path = ''
embed_frameworks.add_file_reference(kit_target.product_reference)
embed_frameworks.files.each do |bf|
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

# iOS App 依赖 watchOS App
ios_target.add_dependency(watch_target)
# "Embed Watch Content" build phase —— 缺了这个 .app 里不会带手表 App
#
# ★ "Embed Watch Content" 必须与真实 Xcode 工程逐字对齐 ★
#
# 对照样本：Bark（Finb/Bark）—— 现代单 target watchOS App 工程，CI 上可正常打包。
#   dstPath           = "$(CONTENTS_FOLDER_PATH)/Watch"
#   dstSubfolderSpec  = 16
#   PBXBuildFile settings = {ATTRIBUTES = (RemoveHeadersOnCopy, )}
#
# 之前用 xcodeproj 的 symbol_dst_subfolder_spec = :products_directory 只写了
# dstSubfolderSpec=16，**没写 dstPath**。缺 dstPath 时 Xcode 不知道该拷到
# 哪个目录，整个 copy phase 被**静默跳过** —— 编译不报错，
# 但产出的 DayEcho.app 里根本没有 Watch/ 目录，
# 表现为「iOS 包里没找到嵌入的 DayEchoWatch.app」。
embed_phase = ios_target.new_copy_files_build_phase('Embed Watch Content')
embed_phase.symbol_dst_subfolder_spec = :products_directory
embed_phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
embed_phase.add_file_reference(watch_target.product_reference)

# build file 的 ATTRIBUTES（真实 Xcode 工程同样有）
embed_phase.files.each do |bf|
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

app_files = Dir.glob(File.join(ROOT, 'Sources/DayEchoApp/**/*.swift'))
                .map { |p| p.sub("#{ROOT}/", '') }
                .sort
raise '★ DayEchoApp 源文件为空 —— glob 失败？' if app_files.empty?
app_group = project.new_group('DayEchoApp', 'Sources/DayEchoApp')
app_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = app_group.new_reference(File.basename(f))
  ios_target.add_file_references([ref])
end

# ---- 资源 ----
res_group = project.new_group('Resources')
catalog_path = File.join(ROOT, 'Resources/Assets.xcassets')
if File.directory?(catalog_path)
  catalog = res_group.new_file(catalog_path)
  ios_target.add_resources([catalog])

  # ★ watch target 也要挂同一个 asset catalog ★
  #
  # 2026-11-18 真机实锤：手表桌面上**找不到 DayEcho**（白图标/无图标）。
  #
  # 根因：xcassets **只**加进了 `ios_target` 的 Resources phase，
  # `watch_target` 完全没有 asset catalog ⇒ actool 从未为 watch
  # 编译任何图标资源 ⇒ 手表上根本没有图标可显示。
  #
  # watchOS 的图标集叫 `WatchAppIcon.appiconset`，
  # 和 iOS 的 `AppIcon.appiconset` 在**同一个** xcassets 里，
  # 通过 `platform: watchos` 区分。
  watch_target.add_resources([catalog])
end

privacy = res_group.new_file(File.join(ROOT, 'legal/privacy_policy.html'))
ios_target.add_resources([privacy])

# ---- 本地化 ----
project.build_configurations.each do |cfg|
  cfg.build_settings['DEVELOPMENT_LANGUAGE'] = 'en'
end
project.root_object.attributes['developmentRegion'] = 'en'
project.root_object.attributes['knownRegions'] = ['en', 'zh-Hans', 'Base']

lproj_group = project.new_group('Localization', 'Sources/DayEchoApp/Resources')
%w[en zh-Hans].each do |lang|
  lproj_path = File.join(ROOT, "Sources/DayEchoApp/Resources/#{lang}.lproj")
  next unless File.directory?(lproj_path)
  vg = lproj_group.new_variant_group("#{lang}.lproj")
  vg.new_reference(File.join(lproj_path, 'Localizable.strings'))
  ios_target.add_resources([vg])
end

# ============================================================
# 5. iOS App Build Settings
# ============================================================
ios_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  s['PRODUCT_NAME'] = 'DayEcho'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  # ★ 用真实的 Info.plist 文件，不用 GENERATE_INFOPLIST_FILE ★
  #
  # ★ 为什么必须用真实文件 ★
  # 1) `INFOPLIST_KEY_UIBackgroundModes` 在 GENERATE_INFOPLIST_FILE=YES 时
  #    会被 Xcode **整体丢弃**（实测 fix4 产物里主 App 无此键）。
  #    丢了它 ⇒ 手机锁屏后无法接收并落盘手表传来的录音。
  # 2) `NSSupportsLiveActivities` 在 pbxproj 里从未出现过，
  #    而 Sources/DayEchoApp/CaptureKeepAlive.swift:103 真的在调
  #    `Activity.request(...)` ⇒ 没有这个键，Live Activity 直接抛错，
  #    录音时没有 Live Activity 保活，系统可能在后台停掉录音进程。
  #
  # ★ 对照组证据（不是「数组语义不支持」）★
  #   INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
  #   → 产物里成功变成 ['UIInterfaceOrientationPortrait']
  #   同样是标量写法 + 同样是 GENERATE_INFOPLIST_FILE=YES，
  #   那个键成功，唯独 UIBackgroundModes 整个被丢。
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['INFOPLIST_FILE'] = 'Sources/DayEchoApp/Info.plist'
  # ★ framework 的 rpath —— 没有它 dyld 找不到 DayEchoKit.framework ★
  #
  # ★ 两个键都要写 ★
  # LD_RUNPATH_SEARCH_PATHS 是 Xcode 15+ 的新键，优先级高于旧的 LD_RUNPATH。
  # 工程级默认已经带了 LD_RUNPATH_SEARCH_PATHS，
  # 只写 LD_RUNPATH 会被工程级的 SEARCH_PATHS 覆盖，
  # 结果产物里 rpath 不是你以为的那条。
  #
  # ★ 这里是 iOS App target（不是 watch）★
  # watch app 也设了 CFBundleDisplayName = DayEcho，
  # 按显示名去定位会改错地方 —— 必须按 target 块定位。
  s['LD_RUNPATH'] = '$(inherited) @executable_path/Frameworks'
  s['LD_RUNPATH_SEARCH_PATHS'] =
    '$(inherited) @executable_path/Frameworks @loader_path/Frameworks'
  # ★ 显示名 / 权限文案 / 后台模式 / Live Activity 全部在
  #   Sources/DayEchoApp/Info.plist 里 ★
  #
  # 本 target 用 GENERATE_INFOPLIST_FILE = 'NO'，
  # 所以 INFOPLIST_KEY_* 这一整套**完全不生效**（会被 Xcode 忽略）。
  # 留在这里会造成「两处真源」，改了一处忘了另一处 ⇒ 产物与预期不符。
  # ⇒ 单一真源 = Sources/DayEchoApp/Info.plist。
  # ★ 已删除 NSHealthShareUsageDescription ★
  # 本项目不接入 HealthKit（仓库里没有任何 HKHealthStore 调用），
  # 声明一个用不到的权限只会让用户在授权弹窗里困惑，
  # App Store 审核也会追问「为什么需要读取健康数据」。用不到就删。
  #
  # ★ iOS 侧的后台音频模式在 Sources/DayEchoApp/Info.plist 里 ★
  # 否则手机在后台时无法接收并落盘手表传来的录音，
  # 用户锁屏后手机端就停止接收 —— 表现为「手机不在身边时手表录音传不过来」。
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
  s['DEVELOPMENT_TEAM'] = ''
  s['CODE_SIGN_IDENTITY'] = ''
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  # ★ App Group entitlements（默认不挂）★
  # 见文件顶部 USE_APP_GROUP 说明。
  if USE_APP_GROUP
    s['CODE_SIGN_ENTITLEMENTS'] = 'legal/DayEchoApp.entitlements'
  end
end

project.build_configurations.each do |cfg|
  cfg.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  cfg.build_settings['SWIFT_VERSION'] = '6.0'
end

# ============================================================
# 5b. DayEchoIntents —— 共享 intent framework（阶段 2.1）
# ============================================================
#
# ★ 为什么需要它 ★
#
# 表盘一键抓拍涉及三个 target：
#   1. watch App          —— 真正录音（必须 App 进程）
#   2. watch Widget Ext   —— Control Widget 入口
#   3. （共用）intent 类型
#
# ②里的 Control WidgetButton(action:) 需要引用 ①里用的**同一个** intent 类型，
# 否则系统调不通（两边是两个不同类型 ⇒ 系统不知道该跑哪个）。
#
# ★ 官方依据 ★
#
# AppIntent 文档原文：
#   "Implement this protocol in a new type or existing type in your
#    app, app extension, framework, or Swift package."
#
# ⇒ framework 是官方明确允许的实现位置。
#
# ★ 为什么不放进 DayEchoKit ★
#
# DayEchoKit 是 SwiftPM target，在 macOS 上也会编译。
# 而 `AudioRecordingIntent` 的 platforms 是
#   iOS 18 / iPadOS 18 / Mac Catalyst 18 / macOS 15 / tvOS 18 / visionOS 2 / watchOS 11
# —— **没有 macOS** ⇒ 放进去会让 `swift build` 直接失败。
#
# ⇒ 单独建一个只由 Xcode 编译的 watchOS framework。
intents_target = project.new_target(:framework, 'DayEchoIntents', :watchos, WATCH_MIN)
intents_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "com.dayecho.intents.#{TEAM_ID}"
  s['PRODUCT_NAME'] = 'DayEchoIntents'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['WATCHOS_DEPLOYMENT_TARGET'] = WATCH_MIN
  s['TARGETED_DEVICE_FAMILY'] = '4'
  s['SUPPORTED_PLATFORMS'] = 'watchos watchsimulator'
  s['SDKROOT'] = 'auto'
  s['DEFINES_MODULE'] = 'YES'
  s['SKIP_INSTALL'] = 'YES'
  s['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'NO'
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  # ★ App Intents 需要这两个 ★
  # 没有它们，系统不会扫描并注册本 framework 里的 intent 类型。
  s['ENABLE_APP_INTENTS_METADATA_GENERATION'] = 'YES'
  s['APP_INTENTS_ENABLE_FLEXIBLE_MATCHING'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
end

intents_files = Dir.glob(File.join(ROOT, 'Sources/DayEchoIntents/**/*.swift'))
                  .map { |p| p.sub("#{ROOT}/", '') }
                  .sort
raise '★ DayEchoIntents 源文件为空 —— glob 失败？' if intents_files.empty?
intents_group = project.new_group('DayEchoIntents', 'Sources/DayEchoIntents')
intents_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = intents_group.new_reference(File.basename(f))
  intents_target.add_file_references([ref])
end

# watch App 依赖 intents framework
watch_target.add_dependency(intents_target)
watch_target.frameworks_build_phase.add_file_reference(intents_target.product_reference)

# ★ watchOS App 同样需要 "Embed Frameworks" ★
#
# watch app 二进制链接 @rpath/DayEchoKit.framework/DayEchoKit
# 和 @rpath/DayEchoIntents.framework/DayEchoIntents，
# 但 watchOS target **连 LC_RPATH 都没有**（Xcode 只给 iOS App 默认值），
# 且同样缺 "Embed Frameworks" 阶段。
# ⇒ 手表上装完点开也是白屏/闪退。
#
# ★ dst_path 必须显式写 ★
# watch app 的产物在 .app/Watch/DayEchoWatch.app/ 内，
# Frameworks 要落在 DayEchoWatch.app/Frameworks/。
# 用 $(CONTENTS_FOLDER_PATH)/Frameworks 让它跟着宿主走。
watch_embed_frameworks = watch_target.new_copy_files_build_phase('Embed Frameworks')
watch_embed_frameworks.symbol_dst_subfolder_spec = :frameworks
# ★ dst_path 必须留空 ★
# dstSubfolderSpec = 10（frameworks）本身就已经表示
# "$(CONTENTS_FOLDER_PATH)/Frameworks"，
# 再写 dst_path = '$(CONTENTS_FOLDER_PATH)/Frameworks'
# 就会变成 DayEchoWatch.app/Frameworks/DayEchoWatch.app/Frameworks/（多一层）。
watch_embed_frameworks.dst_path = ''
watch_embed_frameworks.add_file_reference(watch_kit_target.product_reference)
watch_embed_frameworks.add_file_reference(intents_target.product_reference)
watch_embed_frameworks.files.each do |bf|
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

# ============================================================
# 5c. Widget Extensions（阶段 2.1）
# ============================================================
#
# ★ 两个 extension，各管一件事 ★
#
# 1. `DayEchoWatchWidget`（watchOS）—— 表盘 Control Widget
#    点 complication 直接触发 intent，不打开 App。
#
# 2. `DayEchoWidget`（iOS）—— Live Activity 的界面
#    `ActivityConfiguration` 只能在 Widget Extension 中使用。
#
# ★ 嵌入方式：PlugIns 目录 ★
#
# extension 要放进宿主 app 的 `PlugIns/` 目录。
# 用 `new_copy_files_build_phase` + `dstSubfolderSpec = 13`（PlugIns）。
#
# ★ 为什么 watch extension 放进 watch App 的 PlugIns ★
#
# watchOS 的 Widget Extension 属于 **watch App**，不是 iOS App。
# ⇒ 嵌到 `DayEchoWatch.app/PlugIns/`。
# 这一点容易搞错：放到 iOS App 里，系统在手表上根本找不到它。

# ---- 5c-1. watchOS Widget Extension ----
watch_widget_target = project.new_target(:app_extension, 'DayEchoWatchWidget', :watchos, WATCH_MIN)
watch_widget_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  # ★ watch widget 的 framework rpath ★
  # appex 在 PlugIns/ 下，@executable_path 是 appex 自己，
  # 要用 ../.. 往上两级找宿主 watch app 的 Frameworks/。
  s['LD_RUNPATH'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  s['LD_RUNPATH_SEARCH_PATHS'] =
    '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks @loader_path/Frameworks'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{WATCH_BUNDLE_ID}.widget"
  s['PRODUCT_NAME'] = 'DayEchoWatchWidget'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['WATCHOS_DEPLOYMENT_TARGET'] = WATCH_MIN
  s['TARGETED_DEVICE_FAMILY'] = '4'
  s['SUPPORTED_PLATFORMS'] = 'watchos watchsimulator'
  s['SDKROOT'] = 'auto'
  # ★ 用真实的 Info.plist 文件，不用 GENERATE_INFOPLIST_FILE ★
  #
  # ★ 为什么必须用真实文件 ★
  # 2026-11-17 真机装机炸在这里：
  #   IXErrorDomain Code=2  Failed to create app extension placeholder for
  #                          .../DayEcho.app/PlugIns/DayEchoWidget.appex
  #   IXErrorDomain Code=17 extensionDictionary must be set in placeholder
  #                          attributes for an app extension placeholder
  #
  # 根因：Xcode **不处理** INFOPLIST_KEY_NSExtensionPointIdentifier，
  # 也不处理 INFOPLIST_KEY_NSExtension_NSExtensionPointIdentifier。
  # 两种写法实测都不生成 NSExtension 字典
  # （嵌套写法的产物 plist 里连一个 NSExtensionPointIdentifier 都没有）。
  # ⇒ 只有提供真实 Info.plist 文件才可靠。
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['INFOPLIST_FILE'] = 'Sources/DayEchoWatchWidget/Info.plist'
  # 显示名在各自的 Sources/<target>/Info.plist 里
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['SKIP_INSTALL'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  s['ENABLE_APP_INTENTS_METADATA_GENERATION'] = 'YES'
  # ★ widget extension 只能引用扩展安全的 API ★
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  # ★ App Group entitlements（默认不挂）★
  # 见文件顶部 USE_APP_GROUP 说明。
  #
  # ★ 为什么 Watch Widget 也要 ★
  # Watch Widget 有独立沙盒；没有 App Group 就读不到
  # Watch App / iPhone 主 App 写在共享目录里的数据。
  if USE_APP_GROUP
    s['CODE_SIGN_ENTITLEMENTS'] = 'legal/DayEchoWatchApp.entitlements'
  end
end

watch_widget_files = Dir.glob(File.join(ROOT, 'Sources/DayEchoWatchWidget/**/*.swift'))
                       .map { |p| p.sub("#{ROOT}/", '') }
                       .sort
raise '★ DayEchoWatchWidget 源文件为空 —— glob 失败？' if watch_widget_files.empty?
watch_widget_group = project.new_group('DayEchoWatchWidget', 'Sources/DayEchoWatchWidget')
watch_widget_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = watch_widget_group.new_reference(File.basename(f))
  watch_widget_target.add_file_references([ref])
end

# ★ 真实 Info.plist 必须进 target 的文件列表，否则 Xcode 不会处理它 ★
watch_widget_plist = File.join(ROOT, 'Sources/DayEchoWatchWidget/Info.plist')
unless File.exist?(watch_widget_plist)
  abort '★ 缺少 Sources/DayEchoWatchWidget/Info.plist —— widget extension 无法安装'
end
watch_widget_group.new_reference('Info.plist')

# watch widget extension 依赖 intents framework（引用同一个 intent 类型）
watch_widget_target.add_dependency(intents_target)
watch_widget_target.frameworks_build_phase.add_file_reference(intents_target.product_reference)

# ★ watch widget extension 链接 @rpath/DayEchoIntents.framework/DayEchoIntents ★
# 它装在 DayEchoWatch.app/PlugIns/DayEchoWatchWidget.appex/ 里，
# 所以框架要落在 DayEchoWatch.app/Frameworks/（与宿主 watch app 共用），
# 并且 appex 自己要有能解析到它的 rpath。
watch_widget_embed_frameworks = watch_widget_target.new_copy_files_build_phase('Embed Frameworks')
watch_widget_embed_frameworks.symbol_dst_subfolder_spec = :frameworks
# ★ dst_path 必须留空 ★
# spec=10 已经是 Contents/Frameworks；
# 写成 ../../Frameworks 会多出一层 DayEchoWatchWidget.appex/Frameworks/Frameworks/。
watch_widget_embed_frameworks.dst_path = ''
watch_widget_embed_frameworks.add_file_reference(intents_target.product_reference)
watch_widget_embed_frameworks.files.each do |bf|
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

# ---- 5c-2. iOS Widget Extension（Live Activity 界面）----
ios_widget_target = project.new_target(:app_extension, 'DayEchoWidget', :ios, IOS_MIN)
ios_widget_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_ID}.widget"
  s['PRODUCT_NAME'] = 'DayEchoWidget'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SDKROOT'] = 'auto'
  # ★ 用真实的 Info.plist 文件，不用 GENERATE_INFOPLIST_FILE ★
  #
  # 理由见 watch widget target 处的完整注释：
  # Xcode 不处理 INFOPLIST_KEY_NSExtensionPointIdentifier，
  # 也不处理 INFOPLIST_KEY_NSExtension_NSExtensionPointIdentifier，
  # 两种写法实测都不生成 NSExtension 字典
  # ⇒ 真机安装必报 IXErrorDomain Code=17 (extensionDictionary must be set)。
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['INFOPLIST_FILE'] = 'Sources/DayEchoWidget/Info.plist'
  # 显示名在各自的 Sources/<target>/Info.plist 里
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['SKIP_INSTALL'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  s['ENABLE_APP_INTENTS_METADATA_GENERATION'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  # ★ App Group entitlements（默认不挂）★
  # 见文件顶部 USE_APP_GROUP 说明。
  #
  # ★ 为什么 Widget 也必须要 ★
  # Widget 有**独立沙盒**。没有 App Group entitlement 时，
  # 主 App 写进共享目录的数据，Widget 一个字都读不到
  # ⇒ Widget 侧的共享功能**静默失效**（不报错，只是数据不对）。
  #
  # ★ 实测踩过 ★
  # 2026-11-19 之前 Widget target 压根没配 CODE_SIGN_ENTITLEMENTS，
  # 签名信息里只有 Xcode 自动加的 application-identifier，
  # 没有任何 app-group ⇒ Widget 与主 App 是两个互不可见的世界。
  if USE_APP_GROUP
    s['CODE_SIGN_ENTITLEMENTS'] = 'legal/DayEchoApp.entitlements'
  end
end

ios_widget_files = Dir.glob(File.join(ROOT, 'Sources/DayEchoWidget/**/*.swift'))
                     .map { |p| p.sub("#{ROOT}/", '') }
                     .sort
raise '★ DayEchoWidget 源文件为空 —— glob 失败？' if ios_widget_files.empty?
ios_widget_group = project.new_group('DayEchoWidget', 'Sources/DayEchoWidget')
ios_widget_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = ios_widget_group.new_reference(File.basename(f))
  ios_widget_target.add_file_references([ref])
end

# ★ 真实 Info.plist 必须进 target 的文件列表，否则 Xcode 不会处理它 ★
ios_widget_plist = File.join(ROOT, 'Sources/DayEchoWidget/Info.plist')
unless File.exist?(ios_widget_plist)
  abort '★ 缺少 Sources/DayEchoWidget/Info.plist —— widget extension 无法安装'
end
ios_widget_group.new_reference('Info.plist')

# ---- 5c-3. 嵌入 ----
#
# watch widget extension → DayEchoWatch.app/PlugIns/
watch_widget_embed = watch_target.new_copy_files_build_phase('Embed Widget Extensions')
watch_widget_embed.symbol_dst_subfolder_spec = :plug_ins
watch_widget_embed.dst_path = ''
watch_widget_embed.add_file_reference(watch_widget_target.product_reference)
watch_widget_embed.files.each do |bf|
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
watch_target.add_dependency(watch_widget_target)

# iOS widget extension → DayEcho.app/PlugIns/
ios_widget_embed = ios_target.new_copy_files_build_phase('Embed Widget Extensions')
ios_widget_embed.symbol_dst_subfolder_spec = :plug_ins
ios_widget_embed.dst_path = ''
ios_widget_embed.add_file_reference(ios_widget_target.product_reference)
ios_widget_embed.files.each do |bf|
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
ios_target.add_dependency(ios_widget_target)

# ============================================================
# 6. Scheme
# ============================================================
# 两个 scheme：
#   DayEcho        —— iOS App（含 watchOS 依赖），用 -destination 'generic/platform=iOS Simulator'
#   DayEchoWatch   —— 纯 watchOS，用 -destination 'generic/platform=watchOS Simulator'
#
# 关键：不能用 -sdk iphonesimulator —— 它会把所有 target 的 SDKROOT
# 覆盖成 iphonesimulator，而 watchOS 的 product type spec 只存在于
# watchsimulator 域，报
# "unable to resolve product type ... in domain 'iphonesimulator'"。
# 用 -destination 让 Xcode 按 target 各自解析平台。

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(kit_target)
scheme.add_build_target(watch_kit_target)
scheme.add_build_target(intents_target)
scheme.add_build_target(watch_widget_target)
scheme.add_build_target(watch_target)
scheme.add_build_target(ios_widget_target)
scheme.add_build_target(ios_target)
scheme.set_launch_target(ios_target)
scheme.save_as(PROJ_PATH, 'DayEcho', true)

watch_scheme = Xcodeproj::XCScheme.new
watch_scheme.add_build_target(watch_kit_target)
watch_scheme.add_build_target(intents_target)
watch_scheme.add_build_target(watch_widget_target)
watch_scheme.add_build_target(watch_target)
watch_scheme.set_launch_target(watch_target)
watch_scheme.save_as(PROJ_PATH, 'DayEchoWatch', true)

# ============================================================
# 真机签名配置（DAYECHO_DEVICE_SIGNING=1 时才生效）
# ============================================================
#
# ★ 每个 target 用自己的 profile ★
# Apple 实际签发的（Team H98V6YZ5QL）：
#   iOS Team Provisioning Profile: com.dayecho.app.H98V6YZ5QL
#   iOS Team Provisioning Profile: com.dayecho.app.H98V6YZ5QL.widget
#
# ★ watchOS 的两个 profile 目前尚未签发 ★
# ⇒ watch target 不配 PROVISIONING_PROFILE_SPECIFIER，
#   只配身份与 Team ⇒ 构建能过，真机装机时再补 profile。
#   （缺失时报错会明确指出是哪个 target 缺 profile，不会静默跳过。）
if DEVICE_SIGNING
  IOS_PROFILE   = "iOS Team Provisioning Profile: com.dayecho.app.#{TEAM_ID}"
  IOS_WIDGET_PROFILE = "iOS Team Provisioning Profile: com.dayecho.app.#{TEAM_ID}.widget"

  # 统一的身份 / Team 设置
  # ★ CODE_SIGN_STYLE 必须是 Automatic ★
  # 实测：profile 是 **Xcode managed**（Xcode 自动下载生成的），
  # 若设 Manual 会报：
  #   "Provisioning profile ... is Xcode managed,
  #    but signing settings require a manually managed profile."
  # ⇒ 保持 Automatic，同时用 PROVISIONING_PROFILE_SPECIFIER 精确指定
  #   （Xcode 里叫 "Assigned"），既自动又能挑对 profile。
  # ★ AUTO_PROFILE=1 时不写死 profile 名 ⇒
  #   xcodebuild -allowProvisioningUpdates 会让 Xcode
  #   按 bundle id + entitlements 自动匹配已有 profile，
  #   缺失的（含 watchOS App / watchOS Widget）自动向 Apple 申请签发。
  # ★ 已登录 Apple 账号后这条路才走得通（未登录时 Xcode 无权申请）。
  apply_signing = lambda do |target, profile|
    target.build_configurations.each do |cfg|
      cfg.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
      cfg.build_settings['DEVELOPMENT_TEAM'] = TEAM_ID
      # ★ 必须用**固定 SHA1**，不能用 'Apple Development' 这种名字 ★
      # 实测：钥匙串里同时存在两张同 Team 证书
      #   A1CFBE2B… "iPhone Developer: 551884866@qq.com (4WVTTGB96R)"
      #   D357EDA3… "Apple Development: 551884866@qq.com (4WVTTGB96R)"
      # 按名字匹配会各自选到不同的 ⇒
      #   "Embedded binary is not signed with the same certificate as the parent app"
      # ⇒ 解法：**把只含 A1CF 的自建钥匙串移出搜索列表**，
      #   让全机只剩 login.keychain-db 里的 D357（所有已签发 profile 都含它）。
      #   锁定的唯一身份由 security list-keychains 控制，不写在工程里。
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
  # ★ framework 不支持 provisioning profile ★
  #   报 "DayEchoKit does not support provisioning profiles."
  # ⇒ 只给身份，不给 profile。
  apply_signing.call(kit_target,        nil)
  # ★ watchOS 的 profile 尚未签发 ★
  #   报 "DayEchoWatch requires a provisioning profile with the App Groups feature."
  # ⇒ 暂不挂 profile；只设身份与 Team。
  apply_signing.call(watch_target,        nil)
  apply_signing.call(watch_widget_target, nil)
  apply_signing.call(watch_kit_target,    nil)
  apply_signing.call(intents_target,      nil)

  puts "★ 已启用真机签名配置（Team #{TEAM_ID}）"
end

project.save
puts "已生成 #{PROJ_PATH}"
puts "ios:   #{ios_target.name}  src=#{ios_target.source_build_phase.files.count} res=#{ios_target.resources_build_phase.files.count}"
puts "kit:   #{kit_target.name}  src=#{kit_target.source_build_phase.files.count}"
puts "watch: #{watch_target.name}  src=#{watch_target.source_build_phase.files.count} res=#{watch_target.resources_build_phase.files.count}"
puts "wkit: #{watch_kit_target.name}  src=#{watch_kit_target.source_build_phase.files.count}"
puts "intents: #{intents_target.name}  src=#{intents_target.source_build_phase.files.count}"
puts "wwidget: #{watch_widget_target.name}  src=#{watch_widget_target.source_build_phase.files.count}"
puts "iwidget: #{ios_widget_target.name}  src=#{ios_widget_target.source_build_phase.files.count}"
