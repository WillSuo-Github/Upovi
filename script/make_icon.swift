import AppKit
import Foundation
let path = CommandLine.arguments[1]
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 68, y: 68, width: 888, height: 888)
let shape = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(calibratedRed: 0.18, green: 0.65, blue: 0.95, alpha: 1),
           ending: NSColor(calibratedRed: 0.21, green: 0.29, blue: 0.81, alpha: 1))!.draw(in: shape, angle: -75)
let arc = NSBezierPath()
arc.lineWidth = 72; arc.lineCapStyle = .round
arc.appendArc(withCenter: NSPoint(x: 512, y: 500), radius: 225, startAngle: 35, endAngle: 310, clockwise: false)
NSColor.white.setStroke(); arc.stroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 697, y: 705)); arrow.line(to: NSPoint(x: 736, y: 579)); arrow.line(to: NSPoint(x: 599, y: 612)); arrow.close()
NSColor.white.setFill(); arrow.fill()
let stem = NSBezierPath(); stem.lineWidth = 65; stem.lineCapStyle = .round
stem.move(to: NSPoint(x: 512, y: 370)); stem.line(to: NSPoint(x: 512, y: 602)); stem.stroke()
let head = NSBezierPath(); head.lineWidth = 65; head.lineJoinStyle = .round; head.lineCapStyle = .round
head.move(to: NSPoint(x: 427, y: 520)); head.line(to: NSPoint(x: 512, y: 605)); head.line(to: NSPoint(x: 597, y: 520)); head.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
