#!/usr/bin/env bash
# ============================================================
# DayEcho 明早一次性装机 + 复测脚本
# ============================================================
# 用法：  bash /Users/maike/Desktop/DayEcho/legal/morning_install.sh
#
# 前置条件（由人做）：
#   1. iPhone 用**数据线**接上 Mac
#   2. iPhone **解锁亮屏**（锁屏时 usbmuxd 根本不握手）
#   3. 如提示「信任此电脑」→ 点信任
#   4. Apple Watch 解锁亮屏（配对时要点「信任」）
#
# 脚本会：
#   - 先做**只读门禁体检**（不消耗签名额度）
#   - 门禁全过才发起签名安装
#   - 装完立刻抓真机证据（版本 / bundle id / 崩溃报告）
# ============================================================
set -uo pipefail

IPA="/Users/maike/Desktop/DayEcho-unsigned-2026-11-18-fix3.ipa"
CLI="/Users/maike/Applications/de-install"
ACCOUNT="551884866@qq.com"
LOG="/tmp/de_morning_install.log"

say() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
fail() { printf '\033[1;31m❌ %s\033[0m\n' "$*"; exit 1; }

exec > >(tee -a "$LOG") 2>&1
echo "===== DayEcho 晨间装机  $(date '+%F %T') ====="

# ---------------------------------------------------------
say "步骤 0/5  环境体检"
# ---------------------------------------------------------
command -v security >/dev/null || fail "缺 security 命令"
[ -x "$CLI" ] || fail "缺 CLI: $CLI"
[ -f "$IPA" ] || fail "缺 IPA: $IPA"

PW="$(security find-generic-password -a "$ACCOUNT" -w 2>/dev/null || true)"
[ -n "$PW" ] || fail "Keychain 里读不到 $ACCOUNT 的密码"
echo "  ✅ Keychain 凭据可读（长度 ${#PW}）"

if [ ! -f /tmp/de-store/anisette_state ]; then
  echo "  ⚠️  anisette_state 不在 /tmp/de-store（/tmp 被清过），从备份恢复"
  mkdir -p /tmp/de-store
  cp -R "$HOME/.local/share/de-store/." /tmp/de-store/ 2>/dev/null || true
fi
[ -f /tmp/de-store/anisette_state ] || fail "anisette_state 缺失且无法恢复"
echo "  ✅ anisette 状态就位"

# ---------------------------------------------------------
say "步骤 1/5  只读门禁体检（不消耗签名额度）"
# ---------------------------------------------------------
python3 /Users/maike/Desktop/DayEcho/legal/assert_candidate_refresh.py \
  || fail "门禁失败：候选刷新断言"
python3 /Users/maike/Desktop/DayEcho/legal/assert_widget_entrypoints.py \
  || fail "门禁失败：Widget 入口断言"

TMP="$(mktemp -d)"
unzip -o -q "$IPA" -d "$TMP" || fail "IPA 解压失败"
A="$TMP/Payload/DayEcho.app"

check_plist() { # 路径 键 期望
  local v
  v="$(/usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true)"
  [ "$v" = "$3" ] || fail "  $1 的 $2 = '$v'，期望 '$3'"
  echo "  ✅ $2 = $v"
}

echo "— appex 必须有 NSExtension 字典 —"
for P in "$A/PlugIns/DayEchoWidget.appex" \
         "$A/Watch/DayEchoWatch.app/PlugIns/DayEchoWatchWidget.appex"; do
  /usr/libexec/PlistBuddy -c 'Print :NSExtension' "$P/Info.plist" >/dev/null 2>&1 \
    || fail "$P 缺 NSExtension 字典"
  echo "  ✅ $(basename "$P") 有 NSExtension"
done

echo "— bundle 标识链 —"
check_plist "$A/Info.plist"                                    CFBundleIdentifier "com.dayecho.app"
check_plist "$A/Watch/DayEchoWatch.app/Info.plist"             CFBundleIdentifier "com.dayecho.app.watchkitapp"
check_plist "$A/Watch/DayEchoWatch.app/Info.plist"             WKCompanionAppBundleIdentifier "com.dayecho.app"

echo "— 动态库依赖闭合 —"
for B in "$A/DayEcho" "$A/PlugIns/DayEchoWidget.appex/DayEchoWidget" \
         "$A/Watch/DayEchoWatch.app/DayEchoWatch" \
         "$A/Watch/DayEchoWatch.app/PlugIns/DayEchoWatchWidget.appex/DayEchoWatchWidget"; do
  [ -f "$B" ] || fail "缺可执行文件 $B"
  if otool -L "$B" 2>/dev/null | grep -q '@rpath/DayEchoKit.framework/DayEchoKit'; then
    [ -f "$A/Frameworks/DayEchoKit.framework/DayEchoKit" ] \
      || fail "$B 依赖 DayEchoKit，但框架没嵌入"
    otool -l "$B" 2>/dev/null | grep -q '@executable_path/Frameworks' \
      || fail "$B 缺 @executable_path/Frameworks rpath"
  fi
done
echo "  ✅ 依赖闭合 + rpath 就位"

echo "— 资源 —"
[ -f "$A/Assets.car" ] || fail "主 App 缺 Assets.car"
[ -f "$A/Watch/DayEchoWatch.app/Assets.car" ] || fail "Watch App 缺 Assets.car"
echo "  ✅ Assets.car 就位"

rm -rf "$TMP"

# ---------------------------------------------------------
say "步骤 2/5  等 iPhone 上线"
# ---------------------------------------------------------
for i in $(seq 1 60); do
  N="$(python3 "$HOME/.local/share/de-tools/muxcount.py" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  N="${N:-0}"
  if [ "$N" != "0" ] && [ -n "$N" ]; then
    echo "  ✅ 检测到 $N 台设备"
    break
  fi
  [ $((i % 6)) -eq 0 ] && echo "  …等待中（$((i*10))s），请确认已插线并解锁"
  [ "$i" -eq 60 ] && fail "10 分钟内没等到 iPhone。请检查数据线 / 解锁 / 信任电脑"
  sleep 10
done

# ---------------------------------------------------------
say "步骤 3/5  签名安装（含 Watch companion 配对）"
# ---------------------------------------------------------
export DE_APPLE_ID="$ACCOUNT"
export DE_APPLE_PASSWORD="$PW"
export DE_WAIT_DEVICE=120
export DE_ANISETTE_URL="https://ani.iloader.app"
export HTTP_PROXY="http://127.0.0.1:7897"
export HTTPS_PROXY="http://127.0.0.1:7897"

echo "  ▶ 是我在用你的 Apple ID 登录并签名（账号 $ACCOUNT）"
echo "  ▶ 若提示 2FA，把 6 位验证码贴给我；输入 sms 切短信通道，resend 重推"

"$CLI" "$IPA"
RC=$?
echo "  CLI 退出码 = $RC"
[ "$RC" -eq 0 ] || fail "安装失败（退出码 $RC），日志见 $LOG"

# ---------------------------------------------------------
say "步骤 4/5  装机后核验"
# ---------------------------------------------------------
idevice_id -l || fail "设备不在线"

echo "— 设备上的 provisioning profile（证明签名装上了）—"
ideviceprovision list 2>/dev/null | tee /tmp/de_profiles.txt | head -10 || true
if grep -qi dayecho /tmp/de_profiles.txt 2>/dev/null; then
  echo "  ✅ 设备上有 DayEcho 的 provisioning profile"
else
  echo "  ⚠️ 没在 profile 列表里看到 DayEcho（列表可能不含 App 自身 profile）"
fi

echo "— 拉取设备端崩溃报告 —"
rm -rf /tmp/de_crashes && mkdir -p /tmp/de_crashes
idevicecrashreport /tmp/de_crashes 2>/dev/null || true
CRASH_COUNT="$(find /tmp/de_crashes -name '*.ips' 2>/dev/null | wc -l | tr -d ' ')"
echo "  崩溃报告数：$CRASH_COUNT"
NEW_CRASH="$(find /tmp/de_crashes -name '*DayEcho*' -newermt '-30 minutes' 2>/dev/null | head -5)"
[ -n "$NEW_CRASH" ] && echo "  ⚠️ 有新的 DayEcho 崩溃报告：" && echo "$NEW_CRASH" \
  || echo "  ✅ 没有新的 DayEcho 崩溃报告"

echo "— 拍桌面截图（用来核对图标是不是白方块）—"
if idevicescreenshot /tmp/de_home.png >/dev/null 2>&1; then
  echo "  ✅ 截图已存 /tmp/de_home.png（请解锁后回主屏幕再让我重拍更准）"
else
  echo "  ⚠️ 截图失败（可能需要解锁 + 已挂载开发者镜像）"
fi

# ---------------------------------------------------------
say "步骤 5/5  汇总"
# ---------------------------------------------------------
echo "  装机日志：$LOG"
echo "  崩溃报告：/tmp/de_crashes"
echo
echo "  ★ 还需要你在设备上做（我看不到屏幕）："
echo "    1. 主 App 图标是不是不再是白色方块"
echo "    2. 「手动录入一句话」后待确认列表有没有出现候选"
echo "    3. 长按主屏幕 → 加小组件 → 搜 DayEcho，看 Widget 能不能加"
echo "    4. Apple Watch 上有没有出现 DayEcho"
echo "    5. Watch 弹「信任」时点信任"
echo
echo "===== 完成  $(date '+%F %T') ====="
