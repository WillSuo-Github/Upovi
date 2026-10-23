// Explicit opt-in native UI acceptance tool. Snapshots can contain local app inventory; keep them private.
import AppKit
import ApplicationServices
import Foundation
import CoreGraphics

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of:name), args.indices.contains(index+1) else { return nil }
    return args[index+1]
}
func fail(_ message: String) -> Never { fputs(message+"\n",stderr); exit(1) }
guard AXIsProcessTrusted() else { fail("Accessibility access is unavailable; no permissions were changed.") }
guard let pidText = option("--pid"), let pid = Int32(pidText), let application = NSRunningApplication(processIdentifier:pid),
      ["app.upovi.Upovi", "app.upovi.TrustAcceptance", "com.apple.notificationcenterui", "com.apple.UserNotificationCenter", "com.apple.systempreferences"].contains(application.bundleIdentifier ?? "") else { fail("Select only Upovi, its synthetic trust fixture, its notification UI, or the Upovi notification settings pane.") }
let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root,2)
let action = option("--action") ?? "snapshot"
let wantedRole = option("--role")
let label = option("--label")
if application.bundleIdentifier == "com.apple.systempreferences", !["snapshot", "inspect", "actions"].contains(action) {
    let allowed = (action == "press" && wantedRole == "AXCheckBox" && label == "Allow notifications") ||
        (action == "press" && wantedRole == "AXButton" && ["Upovi, Off", "Upovi, On"].contains(label ?? "")) ||
        (action == "close-window" && wantedRole == "AXWindow" && label == "Upovi")
    guard allowed else { fail("System Settings actions are restricted to Upovi notification controls.") }
}
if action == "type", !["app.upovi.Upovi", "app.upovi.TrustAcceptance"].contains(application.bundleIdentifier ?? "") { fail("Text input is restricted to Upovi.") }
var queue: [(AXUIElement,Int)] = (attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? []).map { ($0,0) }
if wantedRole == "AXMenuItem" || wantedRole == "AXMenuBarItem" {
    for name in [kAXMenuBarAttribute, "AXExtrasMenuBar"] {
        if let bar = attribute(root,name) { queue.append((bar as! AXUIElement,0)) }
    }
}
var snapshot: [[String:Any]] = [], found: AXUIElement?
var index = 0
while index < queue.count, index < 3000 {
    let (element,depth) = queue[index]; index += 1
    let role = attribute(element,kAXRoleAttribute) as? String ?? ""
    let title = attribute(element,kAXTitleAttribute) as? String ?? ""
    let description = attribute(element,kAXDescriptionAttribute) as? String ?? ""
    let value = attribute(element,kAXValueAttribute).map { String(describing:$0) } ?? ""
    let placeholder = attribute(element,kAXPlaceholderValueAttribute) as? String ?? ""
    let enabled = attribute(element,kAXEnabledAttribute) as? Bool ?? true
    let labelElement = attribute(element,kAXTitleUIElementAttribute)
    let associatedLabel: String
    if let labelElement { let target = labelElement as! AXUIElement; associatedLabel = attribute(target,kAXValueAttribute) as? String ?? attribute(target,kAXTitleAttribute) as? String ?? "" } else { associatedLabel = "" }
    snapshot.append(["role":role,"title":title,"description":description,"value":String(value.prefix(600)),"placeholder":placeholder,"label":associatedLabel,"enabled":enabled,"depth":depth])
    if action != "snapshot", (wantedRole == nil || role == wantedRole),
       label == nil || [title,description,value,placeholder,associatedLabel].contains(label!) { found = element; break }
    if depth < 18, !(role == "AXMenuBarItem" && title == "Apple") {
        queue += (attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? []).map { ($0,depth+1) }
    }
}
if action == "actions" {
    guard let found else { fail("Requested control was not found.") }; var names:CFArray?; AXUIElementCopyActionNames(found,&names); print(names as? [String] ?? [])
} else if action == "inspect" {
    guard let last = snapshot.last, found != nil else { fail("Requested control was not found.") };
    let data = try JSONSerialization.data(withJSONObject:last,options:[.sortedKeys]); FileHandle.standardOutput.write(data); print("")
} else if action == "snapshot" {
    let data = try JSONSerialization.data(withJSONObject:snapshot,options:[.sortedKeys,.prettyPrinted])
    FileHandle.standardOutput.write(data); print("")
} else {
    guard var element = found else { fail("Requested control was not found.") }
    guard attribute(element,kAXEnabledAttribute) as? Bool != false else { fail("Requested control is disabled.") }
    let result: AXError
    switch action {
    case "press": result = AXUIElementPerformAction(element,kAXPressAction as CFString)
    case "close-window":
        guard let button = attribute(element,kAXCloseButtonAttribute) else { fail("Window has no close button.") }
        result = AXUIElementPerformAction(button as! AXUIElement,kAXPressAction as CFString)
    case "type":
        guard let value = option("--value") else { fail("Missing --value") }
        _ = AXUIElementSetAttributeValue(element,kAXFocusedAttribute as CFString,kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(root,kAXFrontmostAttribute as CFString,kCFBooleanTrue)
        application.activate()
        usleep(150000)
        for down in [true,false] {
            let key = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down)!; key.flags = .maskCommand; key.postToPid(pid)
        }
        usleep(100000)
        let chars = Array(value.utf16)
        for down in [true,false] {
            let key = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down)!
            key.flags = []
            chars.withUnsafeBufferPointer { key.keyboardSetUnicodeString(stringLength:chars.count,unicodeString:$0.baseAddress) }
            key.postToPid(pid)
        }
        result = .success
    case "set":
        guard let value = option("--value") else { fail("Missing --value") }
        result = AXUIElementSetAttributeValue(element,kAXValueAttribute as CFString,value as CFString)
    case "select-row":
        for _ in 0..<10 {
            if attribute(element,kAXRoleAttribute) as? String == "AXRow" { break }
            guard let parent = attribute(element,kAXParentAttribute) else { fail("No row ancestor") }
            element = parent as! AXUIElement
        }
        result = AXUIElementSetAttributeValue(element,kAXSelectedAttribute as CFString,kCFBooleanTrue)
    default: fail("Unsupported action")
    }
    print("action=\(action) result=\(result.rawValue)")
    if result != .success { exit(2) }
}
