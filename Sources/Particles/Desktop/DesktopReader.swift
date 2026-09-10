import AppKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

struct DesktopDisplay: Identifiable, Sendable {
    let id: UInt32
    let name: String
    let frame: CGRect
}

struct ScanResult: Sendable {
    var items: [DesktopItem] = []
    var stationaryDisplays: Set<UInt32> = []
    var finderStatus = "Connect Finder to read desktop item positions."
    var widgetStatus = ""
}

/// Serializes Finder and Window Server reads away from the UI thread.
actor DesktopReader {
    private let iconGeometry = DesktopIconGeometry()

    /// Perform the protected reads once at launch, even with no balls or desktop
    /// items. macOS remembers each decision; denial must not block the other read.
    func preparePermissions() -> [String] {
        var status: [String] = []
        do {
            let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: false)
            _ = try FileManager.default.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil)
        } catch {
            status.append("Desktop folder access unavailable. Enable Particles → Desktop Folder in System Settings → Privacy & Security → Files and Folders, then relaunch. \(error.localizedDescription)")
        }
        guard !Task.isCancelled else { return status }
        do {
            _ = try readFinderItems()
        } catch {
            status.append(error.localizedDescription)
        }
        return status
    }

    func scan(displays: [DesktopDisplay], anchors: [WindowGeometry.Anchor], readItems: Bool) async -> ScanResult {
        var result = ScanResult()
        if readItems {
            do {
                let desktop = try readFinderItems()
                result.items += await iconGeometry.resolve(desktop.items, previews: desktop.previews)
                result.finderStatus = desktop.skipped == 0
                    ? "\(desktop.items.count) desktop items read from Finder."
                    : "\(desktop.items.count) desktop items read; \(desktop.skipped) positions unavailable. \(desktop.detail)"
                result.finderStatus += desktop.items.first?.size.map {
                    " Icon size: \(Int($0.width)) × \(Int($0.height)) pt (excluding labels)."
                } ?? " Desktop icon size unavailable."
            } catch {
                result.finderStatus = error.localizedDescription
            }
        }
        let widgets = readWidgets(displays: displays, anchors: anchors)
        result.items += widgets.items
        result.stationaryDisplays = widgets.stationaryDisplays
        result.widgetStatus = widgets.status
        return result
    }

    private func readFinderItems() throws -> (items: [DesktopItem], skipped: Int, detail: String, previews: Bool) {
        // Structured Apple event lists preserve punctuation and Unicode in filenames.
        let source = """
        with timeout of 15 seconds
            tell application "Finder"
                set outputRows to {}
                set skippedCount to 0
                set firstError to ""
                -- The desktop view has one shared icon size. Failure to read
                -- this optional setting must not discard item positions.
                set desktopIconSize to 0
                set desktopPreviews to false
                try
                    set desktopIconSize to (get icon size of icon view options of window of desktop) as integer
                end try
                try
                    set desktopPreviews to get shows icon preview of icon view options of window of desktop
                end try
                -- Resolve the Finder collection before iterating. An unresolved
                -- object specifier is not a snapshot of the desktop items.
                set desktopItems to get every item of desktop
                repeat with itemReference in desktopItems
                    set desktopItem to contents of itemReference
                    try
                        set itemName to (get name of desktopItem) as text
                        set itemURL to (get URL of desktopItem) as text
                        try
                            set p to get desktop position of desktopItem
                            set px to (item 1 of p) as integer
                            set py to (item 2 of p) as integer
                        on error
                            -- Some Finder versions only populate the regular position.
                            set p to get position of desktopItem
                            set px to (item 1 of p) as integer
                            set py to (item 2 of p) as integer
                        end try
                        set end of outputRows to {itemName, itemURL, px, py, ((class of desktopItem) is folder)}
                    on error errorMessage number errorCode
                        set skippedCount to skippedCount + 1
                        if errorCode is -1700 then set errorMessage to "Finder did not return coordinates for one or more desktop icons."
                        if firstError is "" then set firstError to errorMessage
                    end try
                end repeat
                return {outputRows, skippedCount, firstError, desktopIconSize, desktopPreviews}
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { throw ReadError.message("Could not prepare the Finder request.") }
        var error: NSDictionary?
        // The Objective-C API can return nil on failure despite its imported signature.
        let response: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw ReadError.message("Finder access denied. Enable Particles → Finder in System Settings → Privacy & Security → Automation, then relaunch the app.")
            }
            throw ReadError.message("Finder: \(error[NSAppleScript.errorMessage] as? String ?? "Unable to read desktop positions.")")
        }
        guard let reply = response, let rows = reply.atIndex(1) else { throw ReadError.message("Finder returned an unexpected response.") }
        var skipped = Int(reply.atIndex(2)?.int32Value ?? 0)
        let iconSide = Int(reply.atIndex(4)?.int32Value ?? 0)
        let iconSize: CGSize? = iconSide > 0 && iconSide < 1_000_000
            ? CGSize(width: iconSide, height: iconSide) : nil
        var items: [DesktopItem] = []
        if rows.numberOfItems > 0 {
            for index in 1...rows.numberOfItems {
                guard let row = rows.atIndex(index), row.numberOfItems == 5,
                      let name = row.atIndex(1)?.stringValue,
                      let url = row.atIndex(2)?.stringValue,
                      let x = row.atIndex(3), let y = row.atIndex(4) else { skipped += 1; continue }
                let point = CGPoint(x: Int(x.int32Value), y: Int(y.int32Value))
                // Finder uses a large sentinel for items with no assigned desktop position.
                guard abs(point.x) < 1_000_000, abs(point.y) < 1_000_000 else { skipped += 1; continue }
                items.append(DesktopItem(id: url, name: name, kind: row.atIndex(5)?.booleanValue == true ? .folder : .file, position: point,
                                         size: iconSize, source: iconSize == nil
                                         ? "Finder · icon center · size unavailable"
                                         : "Finder · icon center · configured icon box, excluding label"))
            }
        }
        return (items, skipped, reply.atIndex(3)?.stringValue ?? "", reply.atIndex(5)?.booleanValue ?? false)
    }

    private func readWidgets(displays: [DesktopDisplay], anchors: [WindowGeometry.Anchor])
        -> (items: [DesktopItem], status: String, stationaryDisplays: Set<UInt32>) {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return ([], "Window information is unavailable in this session.", [])
        }
        // Validate the coordinate space in this query too: a widget scan may land
        // between the geometry poller's last stationary sample and the first swipe.
        let stationaryDisplays = WindowGeometry.stationaryDisplays(in: windows, anchors: anchors)
        var items: [DesktopItem] = []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            guard DesktopGeometry.isDesktopWidget(bundleID: bundleID, layer: layer, frame: frame,
                    alpha: window[kCGWindowAlpha as String] as? Double ?? 1,
                    displays: displays.map(\.frame)) else { continue }

            let label = window[kCGWindowName as String] as? String
            let name = label.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            items.append(DesktopItem(id: "widget-\(id)", name: name ?? "Widget \(id)", kind: .widget,
                                     position: frame.origin, size: frame.size,
                                     source: "Window Server · top-left · inferred widget"))
        }
        items.sort { $0.position.y == $1.position.y ? $0.position.x < $1.position.x : $0.position.y < $1.position.y }
        let status = items.isEmpty
            ? "No desktop widget windows detected on the current Space. Detection depends on macOS’s window layout."
            : "\(items.count) widget windows detected on the current Space. Widget classification is best effort."
        return (items, status, stationaryDisplays)
    }
}

private enum ReadError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
