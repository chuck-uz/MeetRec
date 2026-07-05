// Генерирует AppIcon.png (1024×1024): градиент циан → тёмный, волна и точка записи.
// Запуск: swift app/make-icon.swift <выходной.png>
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Фон: скруглённый квадрат с вертикальным градиентом #22D3EE → #0E7490 → #164E63
let inset: CGFloat = size * 0.08
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.22, cornerHeight: rect.width * 0.22, transform: nil)
ctx.addPath(path)
ctx.clip()

let colors = [
    CGColor(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255, alpha: 1),
    CGColor(red: 0x08 / 255, green: 0x91 / 255, blue: 0xB2 / 255, alpha: 1),
    CGColor(red: 0x16 / 255, green: 0x4E / 255, blue: 0x63 / 255, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: size / 2, y: size - inset),
                       end: CGPoint(x: size / 2, y: inset),
                       options: [])

// Волна: вертикальные скруглённые столбики
let barHeights: [CGFloat] = [0.22, 0.42, 0.62, 0.42, 0.22]
let barWidth = size * 0.062
let gap = size * 0.045
let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
var x = (size - totalWidth) / 2
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
for h in barHeights {
    let barHeight = size * h
    let barRect = CGRect(x: x, y: (size - barHeight) / 2 - size * 0.03, width: barWidth, height: barHeight)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    ctx.addPath(barPath)
    ctx.fillPath()
    x += barWidth + gap
}

// Точка записи в правом верхнем углу
let dotRadius = size * 0.065
let dotCenter = CGPoint(x: rect.maxX - dotRadius * 2.2, y: rect.maxY - dotRadius * 2.2)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotRadius * 1.35, y: dotCenter.y - dotRadius * 1.35,
                           width: dotRadius * 2.7, height: dotRadius * 2.7))
ctx.setFillColor(CGColor(red: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1))
ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                           width: dotRadius * 2, height: dotRadius * 2))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("Иконка сохранена: \(outPath)")
