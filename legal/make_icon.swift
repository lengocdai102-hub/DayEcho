#!/usr/bin/swift
import AppKit

// 生成 DayEcho 应用图标：深蓝渐变底 + 白色声波 + 盾牌勾。
// 语义：录音（声波） + 数据不丢（盾牌）。

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// ---- 背景渐变（深蓝 → 靛蓝，夜里录音的感觉） ----
let bg = NSGradient(colors: [
    NSColor(srgbRed: 0.06, green: 0.11, blue: 0.24, alpha: 1),
    NSColor(srgbRed: 0.16, green: 0.27, blue: 0.51, alpha: 1)
])!
bg.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// ---- 中央声波：一排竖条，高低不同，像实时录音电平 ----
let barCount = 9
let barWidth: CGFloat = 44
let gap: CGFloat = 22
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
var x = (size - totalWidth) / 2 - size * 0.075
let centerY = size * 0.52
let heights: [CGFloat] = [120, 210, 320, 440, 300, 400, 250, 160, 100]

for h in heights {
    let rect = NSRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
    let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    NSColor(srgbRed: 0.42, green: 0.82, blue: 0.94, alpha: 1).setFill()
    path.fill()
    x += barWidth + gap
}

// ---- 盾牌轮廓（右下角，小一点，作为"数据安全"角标） ----
let shield = NSBezierPath()
let sx = size * 0.760
let sy = size * 0.150
let sw = size * 0.215
let sh = size * 0.255
shield.move(to: NSPoint(x: sx + sw / 2, y: sy + sh))
shield.curve(to: NSPoint(x: sx + sw, y: sy + sh * 0.62),
             controlPoint1: NSPoint(x: sx + sw, y: sy + sh * 0.86),
             controlPoint2: NSPoint(x: sx + sw, y: sy + sh * 0.74))
shield.line(to: NSPoint(x: sx + sw, y: sy + sh * 0.30))
shield.curve(to: NSPoint(x: sx + sw / 2, y: sy),
             controlPoint1: NSPoint(x: sx + sw, y: sy + sh * 0.13),
             controlPoint2: NSPoint(x: sx + sw * 0.78, y: sy + sh * 0.04))
shield.curve(to: NSPoint(x: sx, y: sy + sh * 0.30),
             controlPoint1: NSPoint(x: sx + sw * 0.22, y: sy + sh * 0.04),
             controlPoint2: NSPoint(x: sx, y: sy + sh * 0.13))
shield.line(to: NSPoint(x: sx, y: sy + sh * 0.62))
shield.curve(to: NSPoint(x: sx + sw / 2, y: sy + sh),
             controlPoint1: NSPoint(x: sx, y: sy + sh * 0.74),
             controlPoint2: NSPoint(x: sx, y: sy + sh * 0.86))
shield.close()

NSColor(srgbRed: 0.30, green: 0.76, blue: 0.45, alpha: 1).setFill()
shield.fill()

// 盾牌里的白色勾
let check = NSBezierPath()
check.move(to: NSPoint(x: sx + sw * 0.26, y: sy + sh * 0.50))
check.line(to: NSPoint(x: sx + sw * 0.44, y: sy + sh * 0.31))
check.line(to: NSPoint(x: sx + sw * 0.74, y: sy + sh * 0.70))
check.lineWidth = 15
check.lineCapStyle = .round
check.lineJoinStyle = .round
NSColor.white.setStroke()
check.stroke()

img.unlockFocus()

// ---- 输出 ----
let outPath = ProcessInfo.processInfo.environment["ICON_OUT"] ?? "legal/AppIcon-1024.png"
let outURL = URL(fileURLWithPath: outPath)

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("渲染失败\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: outURL)
print("已生成 \(outURL.path)")
