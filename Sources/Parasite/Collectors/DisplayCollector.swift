import Foundation
import AppKit
import CoreGraphics

enum DisplayCollector {
    static func read() -> ([DisplayInfo], String?) {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return ([], "could not enumerate active displays")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &ids, &displayCount) == .success else {
            return ([], "could not read the active display list")
        }

        // NSScreen is the only source of the human-readable panel name, and it is
        // keyed by CGDirectDisplayID in its device description.
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
            }
        }

        var out: [DisplayInfo] = []
        for id in ids {
            let mode = CGDisplayCopyDisplayMode(id)
            // mode.width/height are points; pixelWidth/pixelHeight are real pixels.
            // The ratio between them is the backing scale, and a fractional one is
            // the expensive case worth flagging.
            let pointW = mode?.width ?? Int(CGDisplayPixelsWide(id))
            let pointH = mode?.height ?? Int(CGDisplayPixelsHigh(id))
            let pixelW = mode?.pixelWidth ?? pointW
            let pixelH = mode?.pixelHeight ?? pointH
            let refresh = mode?.refreshRate ?? 0
            let native = nativeResolution(id)

            out.append(DisplayInfo(
                name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"),
                isMain: CGDisplayIsMain(id) != 0,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                pixelWidth: pixelW, pixelHeight: pixelH,
                pointWidth: pointW, pointHeight: pointH,
                nativePixelWidth: native?.width, nativePixelHeight: native?.height,
                // A reported rate of 0 means the panel drives its own timing
                // (common over DisplayPort MST and on some USB-C docks).
                refreshHz: refresh > 0 ? refresh : nil,
                backingScale: pointW > 0 ? Double(pixelW) / Double(pointW) : 1
            ))
        }
        return (out.sorted { $0.isMain && !$1.isMain }, nil)
    }

    /// The panel's own physical resolution.
    ///
    /// Taken from the mode carrying IOKit's native-mode flag, not from the largest
    /// available mode: macOS offers scaled modes *above* native (the "More Space"
    /// settings), so the largest mode is frequently bigger than the panel and using
    /// it would hide exactly the over-rendering this is meant to detect.
    private static func nativeResolution(_ id: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let nativeModeFlag: UInt32 = 0x02000000

        // Duplicate low-resolution modes must be requested explicitly, or the list
        // omits some of the modes that carry the flag.
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return nil }

        // Several modes can carry the flag (differing refresh rates or colour
        // depths); they agree on resolution, so the largest of them is the panel.
        let flagged = modes.filter { $0.ioFlags & nativeModeFlag != 0 }
        guard !flagged.isEmpty else { return nil }

        var best: (width: Int, height: Int)?
        for mode in flagged where mode.pixelWidth * mode.pixelHeight > (best.map { $0.width * $0.height } ?? 0) {
            best = (mode.pixelWidth, mode.pixelHeight)
        }
        return best
    }
}

enum AppCollector {
    static func read() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            // Agents and daemons without a UI are covered by the process table;
            // this list is about what you have actually got open.
            .filter { $0.activationPolicy != .prohibited }
            .map {
                RunningApp(
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "unknown",
                    bundleID: $0.bundleIdentifier,
                    isActive: $0.isActive,
                    isHidden: $0.isHidden,
                    launchedAt: $0.launchDate
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
