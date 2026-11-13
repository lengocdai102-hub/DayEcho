# ACK 往返连线 —— 实现方案（待过目）

> 状态：**方案稿，尚未动代码**
> 基线：`a051faa`（上机前验证清单已补全，CI 第 8 轮全绿）
> 目标：补上项目最后一块功能性缺口 —— 手机端发 ACK、Watch 端收 ACK
> 规模：约 125 行生产代码 + 8 条新单测

---

## 一、为什么必须补（不补会怎样）

现状（已核实，非推断）：

| 环节 | 状态 |
|---|---|
| `SegmentAcknowledgement` 数据结构（含 5 个校验字段） | ✅ 已实现 |
| `AcknowledgementKey` 常量 | ✅ 已实现，但**从未被使用过** |
| Kit 侧 `evaluate(ack, against: entry)` 四字段一致性校验 | ✅ 已实现，H 组 8 条单测全过 |
| Kit 侧 `TransferCoordinator.apply(acknowledgement:)` | ✅ 已实现，**但没有任何调用点** |
| **iPhone 侧发送 ACK** | ❌ **完全没有** |
| **Watch 侧接收 ACK** | ❌ **完全没有** |

**实际后果**：段在 `didFinish` 成功后停在 `.transferred`，**永不流转到 `.verified`**。

| 影响 | 结论 |
|---|---|
| 录音会丢吗 | **不会** —— 正因为永不 `.verified`，保留策略永不删它 |
| 手表空间 | **只增不减** |
| 保留策略 | **形同虚设** |
| 状态机闭环 | **没接上** |

补上之后：段才能被安全地清理，`.pending → .transferred → .verified` 闭环成立。

---

## 二、通道选型（按你的要求，已核对 Apple 真机行为）

### 2.1 回传用 `transferUserInfo`，**不用** `sendMessage`

```swift
WCSession.default.transferUserInfo([AcknowledgementKey.metadataKey: payload])
```

**为什么不用 `sendMessage`** —— 你的判断完全正确，而且这是**决定性的**：

| | `sendMessage` | `transferUserInfo` |
|---|---|---|
| 前提 | 对端**必须处于前台且可达** | 系统可靠队列，**不需要对端唤醒** |
| 手表灭屏 / 息屏 / 后台 | **直接失败** `WCErrorCodeNotReachable`，消息**丢弃** | **排队**，下次唤醒/蓝牙连上必达 |
| 送达保证 | 无 | 系统保证不丢 |
| 适合 | 即时交互指令 | **★ 传输确认 ★** |

iPhone 发 ACK 的时刻，手表大概率正在息屏录音（这正是 DayEcho 的常态）⇒
`sendMessage` **几乎必然丢** ⇒ 段永远收不到 ACK。

⇒ **`transferUserInfo` 是唯一正确选择。**

### 2.2 音频仍走 `transferFile`（不变）

ACK 是小数据（~300 字节），音频是几 MB。两者职责分离，不混用。

### 2.3 `transferUserInfo` 的 API 形态

```swift
// ★ 注意签名：单个字典参数，不是 (info, reply) 双参数形式 ★
func transferUserInfo(_ userInfo: [String : Any]) -> WCSessionUserInfoTransfer
```

⚠️ **CI 风险点**：这个 API 在不同 SDK 上的形态容易记错。
我会在本机用 `swiftc -parse` + 提交前人工核对，并在 CI 首轮日志里重点看这一行。

---

## 三、数据协议

### 3.1 ACK 的传输格式

```
userInfo = [
  "dayecho.ack": "<ACK 的 JSON 字符串>"
]
```

- **用 JSON 字符串**，不用 `Codable` 自动编码成 `Data` ——
  `userInfo` 的值必须是 **property list 类型**（String / NSNumber / Data / Array / Dict），
  `Data` 也能传，但 JSON 字符串便于在 Xcode 控制台直接肉眼检查（真机排障很关键）。
- `SegmentAcknowledgement` 已经是 `Codable` ⇒ 用 `JSONEncoder` 一行搞定。
- 解码用 `JSONDecoder` + `Date` 策略要一致（默认 `.deferredToDate` 双端一致即可）。

### 3.2 ★ 关键设计：iPhone 侧如何拿到 `segmentID` ★

ACK 的 `segmentID` **必须**等于 Watch 队列条目的 `entry.id`，否则 `evaluate` 会返回
`.ignoreMismatch` ⇒ ACK 被忽略 ⇒ 段永不 `.verified`。

Watch 侧 `send()` 里已经传了这个值：

```swift
let metadata: [String: Any] = [
  "entryID": payload.entry.id.uuidString,   // ★ 就是 entry.id ★
  "sessionID": ...,
  "fileName": ...,
  "byteCount": ...,
  "sha256": ...,
  "sequence": ...,
  "startedAt": ...,
  "endedAt": ...
]
```

**但 iPhone 侧目前没读它。** 需要补：

```swift
let entryID = (meta["entryID"] as? String).flatMap(UUID.init(uuidString:))
```

**★ 降级路径（重要）★**

`file.metadata` 是**可选**的（第 7 轮刚修过这个坑）。如果 `entryID` 缺失：

| 情况 | 处理 |
|---|---|
| `entryID` **有** | 构造完整 ACK（四字段齐全）→ `evaluate` 可正常匹配 |
| `entryID` **没有**，但 `sessionID`+`sequence`+`sha256` 有 | 构造**降级 ACK**：`segmentID` 填一个**随机 UUID**，`isVerified = false`，`reason = "缺少 entryID，无法安全确认"` |
| `sha256` 缺失/为空 | 同上，`reason = "缺少校验基准，无法确认"` |

**★ 降级 ACK 绝不能被当成成功 ★**
`segmentID` 是随机 UUID ⇒ `evaluate` 必然返回 `.ignoreMismatch` ⇒ **什么都不做**。
这正是我们要的：**宁可不确认，也不能错确认**。

**为什么不做「按 sha256 反查 segmentID」的兜底？**
技术上可以在 iPhone 侧按 sha256 反查，但手机端**没有** Watch 的队列快照
（`pendingEntries()` 从未被调用过），无法可靠映射。
**宁可放弃这次确认，等 Watch 重传时补上 metadata。**
—— 重传的代价是几 MB 流量，错误确认的代价是**永久丢失用户录音**。

### 3.3 ACK 的 `sha256` 用哪个值？

**用手机端重算的 SHA-256**（不是从 metadata 抄来的 `expectedSHA`）。

理由：`evaluate` 会比对 `ack.sha256 == entry.sha256`。
如果 ACK 里抄的是 metadata 里的期望值，那这个比对**永远成立**，二次确认就形同虚设。
用重算值 ⇒ 「手机端独立算出的哈希 == 手表端记录的哈希」⇒ 真正验证了内容一致。

---

## 四、实现分解

### 4.1 iPhone 侧：`PhoneReceiveChannel`（+45 行）

**改动 1：新增 ACK 发送方法**

```swift
/// ★ 回传 ACK —— 用 transferUserInfo，不用 sendMessage ★
///
/// iPhone 发 ACK 时手表大概率处于息屏/后台未激活状态，
/// sendMessage 会直接报 WCErrorCodeNotReachable 并丢弃消息。
/// transferUserInfo 走系统可靠队列，手表下次唤醒必然送达。
private func sendAcknowledgement(
    segmentID: UUID?,
    sessionID: UUID?,
    sequence: Int?,
    sha256: String?,
    isVerified: Bool,
    reason: String?
) {
    let ack = SegmentAcknowledgement(
        segmentID: segmentID ?? UUID(),      // ★ 缺失 ⇒ 随机 ID ⇒ 必然 ignoreMismatch ★
        sessionID: sessionID ?? UUID(),
        sequence: sequence ?? 0,
        sha256: sha256 ?? "",
        isVerified: isVerified,
        reason: reason
    )
    guard let payload = try? JSONEncoder().encode(ack),
          let json = String(data: payload, encoding: .utf8) else { return }

    WCSession.default.transferUserInfo([
        AcknowledgementKey.metadataKey: json
    ])
}
```

**改动 2：在 `didReceive file:` 的三个出口分别调用**

| 出口 | `isVerified` | `reason` |
|---|---|---|
| 校验通过 + 写入录音库成功 | `true` | nil |
| 校验通过但写入录音库失败 | `false` | `"写入录音库失败：…"` |
| 校验不通过（empty/sizeMismatch/hashMismatch） | `false` | 具体原因 |
| 落盘失败（moveItem 抛错） | `false` | `"接收后落盘失败：…"` |

**★ 注意落盘失败那个出口 ★**
现在那里是直接 `return`，**必须先发 ACK 再 return** ——
否则 Watch 端会一直等一个永远不会来的确认。
虽然 `isVerified = false` 的 ACK 只会让段留在队列（安全），
但发出去能让 Watch 端立刻知道「失败原因」，UI 上能显示。

**改动 3：`sha256` 用重算值**

```swift
let computedSHA = Digest.sha256(of: data)   // ★ 重算，不是抄 metadata ★
```

**★ 已核实：不需要新增任何公开方法 ★**
`Digest` 是 `public enum Digest`（`Sources/DayEchoKit/RecordingStore.swift`），
`sha256(of:)` 已是 public 静态方法，直接用。

（`SegmentVerifier` 在 `Sources/DayEchoKit/Transfer.swift`，它是**校验器**
—— `verify(data:expectedSHA256:expectedByteCount:)` 返回校验结论，
不暴露「只算哈希」的接口。走 `Digest` 是对的。）

**改动 4：iPhone 侧实现 `didReceiveUserInfo`（接收方向的反向，本项目用不到，可留空）**

```swift
public func session(_ session: WCSession,
                    didReceiveUserInfo userInfo: [String: Any] = [:]) {
    // 本项目传输方向是 Watch → iPhone，iPhone 不需要接收 ACK。
    // 保留空实现以满足 WCSessionDelegate 要求。
}
```
（**已经有了**，只需加一行注释说明。）

### 4.2 Watch 侧：`WatchSessionCoordinator`（+35 行）

**改动 1：新增 `didReceiveUserInfo` 处理 ACK**

```swift
/// ★ 收到手机端 ACK ★
nonisolated func session(_ session: WCSession,
                         didReceiveUserInfo userInfo: [String: Any]) {
    guard let json = userInfo[AcknowledgementKey.metadataKey] as? String,
          let data = json.data(using: .utf8),
          let ack = try? JSONDecoder().decode(SegmentAcknowledgement.self, from: data)
    else { return }

    // ★ 跨隔离域只传 Sendable 的 SegmentAcknowledgement ★
    // —— 它是 struct + Sendable，JSON 解码出来的值可以直接传。
    Task { @MainActor in
        WatchRecorder.shared.handleAcknowledgement(ack)
    }
}
```

**★ 为什么这里可以安全地 `Task { @MainActor }` ★**
`SegmentAcknowledgement` 是 `public struct ... Sendable` ⇒ 捕获进主线程闭包安全。
**这与第 5 轮修的 `WCSessionFileTransfer` 问题不同** —— 那个是 non-Sendable 的 class。

**改动 2：`WatchRecorder.handleAcknowledgement(_:)`（+20 行）**

```swift
/// ★ 处理手机端回传的 ACK ★
func handleAcknowledgement(_ ack: SegmentAcknowledgement) {
    guard let coordinator else { return }

    // ★ 幂等：重复收到同一段的 ACK 完全安全 ★
    // —— markVerified 是「从队列移除该 ID」，
    //    第二次调用时队列里已经没有这个 ID ⇒ no-op。
    //    evaluate 找不到条目时返回 .ignoreMismatch（不是错误）。
    let action = coordinator.apply(acknowledgement: ack)

    switch action {
    case .confirmVerified:
        // ★ 只有这一步才允许从队列移除 ★
        saveQueue()
        pendingCount = queue.pendingCount
    case .keepPending(let reason):
        // 校验未通过 —— 保留条目，等重试
        saveQueue()
        pendingCount = queue.pendingCount
        lastError = "手机端校验未通过：\(reason)"
    case .ignoreMismatch:
        // ★ 什么都不做 —— 错配的 ACK 绝不能导致删除 ★
        break
    }
}
```

**★ 关键：`saveQueue()` 必须调用 ★**
`markVerified` 只改了内存里的队列。不落盘的话，
下次冷启动 `loadQueue()` 会把段读回来 ⇒ **又变回待传** ⇒ 重复传输。

### 4.3 幂等性与防重放（按你的要求核对）

| 场景 | 行为 | 是否安全 |
|---|---|---|
| 同一段的 ACK 收到 2 次 | 第 1 次 `markVerified`（移除）；第 2 次 `entry(withID:)` 找不到 ⇒ `.ignoreMismatch` ⇒ no-op | ✅ 安全 |
| ACK 与队列条目字段对不上 | `evaluate` 逐项校验 segmentID / sessionID / sequence / sha256 ⇒ `.ignoreMismatch` ⇒ **什么都不做** | ✅ 安全（H8 已覆盖） |
| 旧 ACK 迟到（该段已被移除） | `entry(withID:)` 找不到 ⇒ `.ignoreMismatch` | ✅ 安全 |
| ACK 乱序到达 | 按 segmentID 精确匹配，无顺序依赖 | ✅ 安全 |
| ACK 重放（攻击者伪造） | sha256 必须与本地条目一致 ⇒ 伪造不了 | ✅ 安全 |

**★ 幂等性保障点：`markVerified` 的实现是 `entries.removeAll { $0.id == id }` ★**
—— 天然幂等，重复调用不会出错。

### 4.4 冷启动恢复的衔接

**当前行为**：`recoverInterrupted()` 只把 `.inFlight` 重置为 `.pending`。

**补 ACK 后的行为**：

| 冷启动时的段状态 | 处理 | 是否正确 |
|---|---|---|
| `.inFlight` | 重置为 `.pending` ⇒ 重传 | ✅ 正确（手机端可能没收到） |
| `.transferred` | **保持不动** | ✅ 正确（可能 ACK 在路上，也可能手机端没收到 —— 两种情况都需要保持 `.transferred`？） |

**★ 这里有一个必须决定的语义问题 ★**

段停在 `.transferred` 表示「文件已交给系统队列，但没收到 ACK」。
冷启动后有两种可能：
1. ACK 其实在路上（手表重启时把已收到的 userInfo 丢了）⇒ 应该重传或保持等待；
2. 手机端根本没收到文件（手机当时离线）⇒ 应该重传。

**两种情况的正确处理都是「重传」** —— 因为重传是幂等的：
手机端如果已经收到过，会因为文件已存在而（由我们设计的策略）跳过或覆盖；
手机端如果没收到，就补上了。

**但当前 `nextBatch` 只捞 `.pending` 和 `.failed`** ⇒ `.transferred` 的段**永远不会被重传**！

⇒ **这是补 ACK 时必须一并解决的一个真实缺口。**

**方案（二选一，我推荐 A）**：

| 方案 | 做法 | 优劣 |
|---|---|---|
| **A（推荐）** | 冷启动时把 `.transferred` 也重置为 `.pending` | ★ 简单可靠。代价：手机端已收到的段会被重传一次（浪费一点流量，但**不会造成数据错误** —— 手机端按 sha256 识别，重复文件不重复入库） |
| B | 保留 `.transferred`，等 ACK 超时（如 10 分钟）再重置为 `.pending` | 更省流量，但需要引入超时状态机 + 定时器，复杂度高，且 watchOS 后台定时器不可靠 |

**我推荐 A** —— 理由：**「重复传输」的代价远小于「一段录音永远传不过去」的代价**，
而且符合「数据一个字节都不丢」的核心原则。

**★ 这一条需要你拍板 ★**
它会影响「冷启动恢复」的单测期望（G3 系列）。

### 4.5 ★★ 已核实的副作用：手机端会重复入库 ★★

**（动手前已查实，不是猜测）**

`RecordingStore.addSegment` 的实现（`Sources/DayEchoKit/RecordingStore.swift`）：

```swift
let segmentID = UUID()                        // ★ 每次都生成新 ID ★
let relPath = "segments/\(sessionID)/\(segmentID).m4a"
try AtomicFile.write(data, to: dest)          // ★ 写入新文件 ★
let checksum = Digest.sha256(of: data)
let segment = AudioSegment(id: segmentID, ...)
try queue.sync {
    ...
    index.segments.append(segment)            // ★ 无条件追加，无去重 ★
    ...
}
```

**结论：手机端 `addSegment` 没有任何去重逻辑。**

⇒ **方案 A 落地后，手表重传的段会在手机端入库两次**：
- 时间线上出现**重复段**（同一段音频两遍，各有独立 `segmentID`）；
- `sessions[si].segmentIDs` 多挂一个 ID；
- 存储翻倍。

**这不是「小瑕疵」** —— 对用户就是「同一段录音在 App 里出现两遍」。

#### 解法：按 sha256 + sequence 去重（推荐，改动极小）

在 `addSegment` 写文件**之前**先查索引：

```swift
// ★ 幂等去重：同一段重传时 sha256 + sequence 相同 ★
// —— 重传是系统行为（冷启动重置 .transferred、失败重试），
//    同一段内容可能被投递多次。库里已有一份时直接复用，不重复写盘。
let checksum = Digest.sha256(of: data)   // ★ 提前算（原本在写盘之后）★
if let existing = index.segments.first(where: {
    $0.sha256 == checksum && $0.sequence == sequence
}) {
    return existing     // ★ 复用已有段，不追加、不写盘 ★
}
```

**要点**：
- 比对 `sha256` + `sequence`；
- `checksum` 提前算（原本在写盘之后）；
- 返回 `existing` 而非抛错 ⇒ `PhoneReceiveChannel` 照常发 `isVerified = true` 的 ACK
  ⇒ Watch 端段正常流转 `.verified` ⇒ **闭环成立**。

**同时解决三件事**：重传不产生重复段、不浪费存储、仍能被正确确认为「已送达」。

#### 另一条思路（不推荐，记录备查）

让 ACK 的 `segmentID` 直接当手机端 `segmentID`（不再 `UUID()` 新生成）。
但 `AudioSegment.id` 与 `PendingTransferQueue.Entry.id` 是两套 ID 空间，
改动面大且牵动索引结构 —— **收益不抵风险，放弃。**

---

## 五、新增单测（8 条，全部可在本机跑）

| # | 测什么 | 断言 |
|---|---|---|
| I1 | ACK 正常往返 → 段流转 `.verified` 并从队列移除 | `queue.allEntries.count == 0` |
| I2 | **重复收到同一 ACK（幂等）** | 第一次移除成功；第二次 `.ignoreMismatch`，队列仍为 0，不报错 |
| I3 | ACK 的 sha256 与条目不符 | `.ignoreMismatch`，**段仍在队列**（不删） |
| I4 | ACK 的 sequence 不符 | `.ignoreMismatch`，段仍在队列 |
| I5 | ACK 的 sessionID 不符 | `.ignoreMismatch`，段仍在队列 |
| I6 | **冷启动：`.transferred` 的段被重置为 `.pending` 并可重传** | （方案 A 生效后） |
| I7 | **手机端重复入库去重**：同一段（sha256+sequence 相同）再次入库 | 库中**只有一条**，返回的是已有那条 |
| I8 | **重传仍能被正确确认**：去重路径返回的段，ACK 依然是 `isVerified = true` | Watch 端段正常流转 `.verified` |

**I2 是关键** —— 它直接验证你要求的「幂等与防重放」。

**另需加 1 条反向破坏性验证**（照 H 组的做法）：
把 `markVerified` 的条件改坏 → I2/I3 必须失败 → 恢复 → 全绿。
**证明测试真的能抓住「误删」和「幂等被破坏」。**

---

## 六、改动清单与影响面

| 文件 | 改动 | 行数 | 风险 |
|---|---|---|---|
| `Sources/DayEchoApp/PhoneReceiveChannel.swift` | 发 ACK | +45 | 低 |
| `Sources/DayEchoWatchApp/WatchSessionCoordinator.swift` | 收 ACK | +35 | 中（跨 actor + 新 delegate 方法） |
| `Sources/DayEchoWatchApp/WatchApp.swift` | `handleAcknowledgement` | +20 | 低 |
| `Sources/DayEchoKit/RecordingStore.swift` | `addSegment` 加 sha256+sequence 去重 | +12 | 中（影响索引语义） |
| `Sources/DayEchoKit/Transfer.swift` | 冷启动重置 `.transferred`（方案 A） | +6 | 中（影响 G3 单测） |
| `Sources/DayEchoTestCases/` | 新增 I 组单测 | +90 | 低 |

**合计约 220 行（含单测）**，生产代码约 125 行。

**★ 风险点（都已在上面给出对策）★**

| 风险 | 对策 |
|---|---|
| `transferUserInfo` API 签名记错 | CI 首轮就能发现；我会先查 SDK 头文件再写 |
| Swift 6 并发：`didReceiveUserInfo` 捕获 non-Sendable | `SegmentAcknowledgement` 是 Sendable struct ⇒ 安全 |
| `didReceiveUserInfo` 在 watchOS 上是否必需 | watchOS 的 `WCSessionDelegate` **不要求**实现它，但实现了也无害 |
| 改冷启动语义影响 G3 单测 | 同步更新 G3 期望值，并在文档记录 |
| 手机端重传的段重复入库 | **已核实会重复** ⇒ `addSegment` 加 sha256+sequence 去重（见 4.5 节） |

**★ 核实完毕的结论（动手前已查实）★**

| 待核实项 | 结论 |
|---|---|
| `SegmentVerifier` 是否暴露 SHA-256 接口 | ❌ 没有，但**不需要** —— `Digest.sha256(of:)` 已是 public（`RecordingStore.swift`） |
| `RecordingStore.addSegment` 是否按 sha256 去重 | ❌ **没有** —— `index.segments.append(segment)` 无条件追加 ⇒ 重传会重复入库 ⇒ **解法见 4.5 节** |

---

## 七、执行顺序

1. ~~核实 `RecordingStore.addSegment` 去重语义 + SHA-256 接口~~ ✅ **已完成**（结论见 4.5 / 第六节）
2. 先写 **I 组单测**（含反向破坏性验证）—— 测试先行
3. 实现 `RecordingStore.addSegment` 去重（4.5 节）
4. 实现 Kit 层冷启动重置（`.transferred` → `.pending`）
5. 实现 iPhone 侧发 ACK
6. 实现 Watch 侧收 ACK
7. 本地跑全量（74 + 8 = 82 条）+ 8 道防线
8. 补文档（`docs/测试方法与结论.md` + `docs/上机前验证清单.md`）
9. 提交推送 → CI → 出新 `.ipa`

**预计 1～2 轮 CI。** 如果你那边真机实测同时发现别的 UI/蓝牙问题，正好合并进同一版。

---

## 八、★ 需要你拍板的两点 ★

### 拍板 1：冷启动时 `.transferred` 的段怎么处理？

- **A（我推荐）**：冷启动时把 `.transferred` 也重置为 `.pending` ⇒ 会重传
- **B**：保留 `.transferred` 等 ACK 超时再重传（更省流量，但复杂且 watchOS 定时器不可靠）

### 拍板 2：iPhone 端 `entryID` 缺失时怎么办？

- **A（我推荐）**：发 `isVerified = false` 的降级 ACK（segmentID 随机）⇒ 必然被 ignore ⇒ 安全但放弃本次确认，等重传补 metadata
- **B**：直接不发 ACK ⇒ Watch 端一直等（效果类似，但 Watch 端 UI 看不到原因）

**两个我都是推荐 A。** 你点头（或直接说「按你推荐的来」）我就开工。
