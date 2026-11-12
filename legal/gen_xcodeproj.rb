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
# watchOS 11 起支持 AVAudioSession 的 .allowBluetooth（蓝牙麦克风），
# 对全天录音是实打实的需求。竞品 Auday 同样要求 watchOS 11。
WATCH_MIN = '11.0'
BUNDLE_ID = 'com.dayecho.app'
WATCH_BUNDLE_ID = 'com.dayecho.app.watchkitapp'

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
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.dayecho.kit'
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
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.dayecho.kit.watch'
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
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'DayEcho'
  # ★ 现代 SwiftUI watch App 的必需标记键
  s['INFOPLIST_KEY_WKApplication'] = 'YES'
  # 依附式手表 App：反向绑定到宿主 iOS App
  s['INFOPLIST_KEY_WKCompanionAppBundleIdentifier'] = BUNDLE_ID
  # 依附式（不是独立手表 App）
  s['INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp'] = 'NO'
  # ★ 绝不能设 WKWatchOnly=YES（那是独立手表 App 语义，与嵌入互斥）
  s.delete('INFOPLIST_KEY_WKWatchOnly')
  # ★ 麦克风权限声明（watchOS 必填）★
  # 漏掉这条的真实后果：在手表上点「开始录音」会被系统直接拒绝，
  # AVAudioSession 激活失败，而且**没有任何错误提示**——
  # 表现为「按了没反应」。iOS 侧声明了不代表 watch 侧自动继承，
  # 每个 target 都要各自声明自己的权限。
  s['INFOPLIST_KEY_NSMicrophoneUsageDescription'] =
    'DayEcho 需要麦克风来录制你的语音片段。录音只保存在你的设备上。'
  # ★ 后台音频模式（全天录音的正解）★
  #
  # UIBackgroundModes = audio 是 watchOS 上持续录音的关键：
  # 只要音频录制会话处于激活状态，watchOS 就不会因锁屏/息屏挂起进程，
  # 录音可以持续进行。
  #
  # WKExtendedRuntimeSession 不能替代它 —— 那个 API 有严格的系统时长配额，
  # 是给闹钟/正念/理疗这类短时场景设计的，用来做全天录音会被系统掐断。
  # 这里把 WKExtendedRuntimeSession 当作补充保活手段，UIBackgroundModes 才是主力。
  s['INFOPLIST_KEY_UIBackgroundModes'] = ['audio']
  # 前台持续显示录音状态（用户能一眼看出在录音）
  s['INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents'] = 'YES'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['SKIP_INSTALL'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
end

# watch app 依赖 watchOS 版 Kit
watch_target.add_dependency(watch_kit_target)
watch_target.frameworks_build_phase.add_file_reference(watch_kit_target.product_reference)

# watch app 的业务源码（SwiftUI @main 入口就在这里）
watch_files = %w[
  Sources/DayEchoWatchApp/WatchApp.swift
  Sources/DayEchoWatchApp/WatchTransferChannel.swift
  Sources/DayEchoWatchApp/WatchSessionCoordinator.swift
]
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

app_files = %w[
  Sources/DayEchoApp/DayEchoApp.swift
  Sources/DayEchoApp/ContentView.swift
  Sources/DayEchoApp/PhoneReceiveChannel.swift
]
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
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'DayEcho'
  s['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  s['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait'
  s['INFOPLIST_KEY_NSMicrophoneUsageDescription'] =
    'DayEcho 需要麦克风来录制你的语音片段。录音只保存在你的设备上。'
  # ★ 已删除 NSHealthShareUsageDescription ★
  # 本项目不接入 HealthKit（仓库里没有任何 HKHealthStore 调用），
  # 声明一个用不到的权限只会让用户在授权弹窗里困惑，
  # App Store 审核也会追问「为什么需要读取健康数据」。用不到就删。
  #
  # ★ 顺带：iOS 侧也需要后台音频模式 ★
  # 否则手机在后台时无法接收并落盘手表传来的录音，
  # 用户锁屏后手机端就停止接收 —— 表现为「手机不在身边时手表录音传不过来」。
  s['INFOPLIST_KEY_UIBackgroundModes'] = ['audio', 'processing']
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
  s['DEVELOPMENT_TEAM'] = ''
  s['CODE_SIGN_IDENTITY'] = ''
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
end

project.build_configurations.each do |cfg|
  cfg.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  cfg.build_settings['SWIFT_VERSION'] = '6.0'
end

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
scheme.add_build_target(watch_target)
scheme.add_build_target(ios_target)
scheme.set_launch_target(ios_target)
scheme.save_as(PROJ_PATH, 'DayEcho', true)

watch_scheme = Xcodeproj::XCScheme.new
watch_scheme.add_build_target(watch_kit_target)
watch_scheme.add_build_target(watch_target)
watch_scheme.set_launch_target(watch_target)
watch_scheme.save_as(PROJ_PATH, 'DayEchoWatch', true)

project.save
puts "已生成 #{PROJ_PATH}"
puts "ios:   #{ios_target.name}  src=#{ios_target.source_build_phase.files.count} res=#{ios_target.resources_build_phase.files.count}"
puts "kit:   #{kit_target.name}  src=#{kit_target.source_build_phase.files.count}"
puts "watch: #{watch_target.name}  src=#{watch_target.source_build_phase.files.count} res=#{watch_target.resources_build_phase.files.count}"
puts "wkit: #{watch_kit_target.name}  src=#{watch_kit_target.source_build_phase.files.count}"
