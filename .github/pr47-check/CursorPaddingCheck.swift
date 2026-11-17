import AppKit

typealias Actions = MACCursorActions

@MainActor
final class RegistrationRecorder {
    var calls: [Actions.Registration] = []
    var rejectPadded = false
    var options: [String: Any] = [:]
    var isTahoe = true
    var baseline: Data?

    func engine() -> Actions {
        Actions(operations: .init(register: {
            self.calls.append($0)
            return !self.rejectPadded || $0.size.width < 96
        }, activate: { _ in }, unregisterAll: {}, selectCore: { _ in }, selectArrow: {},
        dockOverride: { _ in }, getScale: { 1 }, setScale: { _ in true },
        isTahoe: { self.isTahoe },
        tahoeAliases: { self.isTahoe ? MACCursorDefinitions.tahoeAliases(for: $0) : [] },
        browserAliases: { MACCursorDefinitions.browserAliasMap[$0] ?? [] },
        readFile: { _ in self.baseline }, defaultPath: { "/baseline.cursor" },
        readPreference: { self.options[$0] }, writePreference: { _, _ in }))
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func makeFrames(_ width: Int, _ height: Int, _ count: Int) -> CGImage {
    let canvas = MACCursorShadow.makeContext(width: width, height: height * count)!
    canvas.clear(CGRect(x: 0, y: 0, width: width, height: height * count))
    for index in 0..<count {
        let top = (count - 1 - index) * height
        canvas.setFillColor(red: CGFloat(index + 1) / CGFloat(count + 1), green: 0.5, blue: 0.75, alpha: 1)
        canvas.fill(CGRect(x: 2, y: top + height / 2, width: width / 2, height: height / 2 - 2))
        canvas.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        canvas.fill(CGRect(x: 0, y: top, width: 3, height: 3))
    }
    return canvas.makeImage()!
}

func normalizedPixels(_ image: CGImage) -> Data {
    let context = MACCursorShadow.makeContext(width: image.width, height: image.height)!
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes: context.data!, count: context.bytesPerRow * image.height)
}

func checkCanvas(_ source: CGImage, _ result: CGImage, frames: Int) {
    let oldHeight = source.height / frames
    let newHeight = result.height / frames
    for i in 0..<frames {
        let original = source.cropping(to: CGRect(x: 0, y: i * oldHeight, width: source.width, height: oldHeight))!
        let actual = result.cropping(to: CGRect(x: 0, y: i * newHeight, width: source.width, height: oldHeight))!
        require(normalizedPixels(original) == normalizedPixels(actual), "Pixels, position, or frame order changed at frame \(i)")
        let right = result.cropping(to: CGRect(x: source.width, y: i * newHeight, width: result.width - source.width, height: newHeight))!
        let bottom = result.cropping(to: CGRect(x: 0, y: i * newHeight + oldHeight, width: source.width, height: newHeight - oldHeight))!
        require(normalizedPixels(right).allSatisfy { $0 == 0 }, "Right padding was not transparent")
        require(normalizedPixels(bottom).allSatisfy { $0 == 0 }, "Bottom padding was not transparent")
    }
}

@main
struct CursorPaddingCheck {
    @MainActor static func main() {
        let id = "com.apple.coregraphics.Arrow"
        let cursor: [String: Any] = [
            "FrameCount": NSNumber(value: 8), "FrameDuration": NSNumber(value: 0.0875),
            "HotSpotX": NSNumber(value: 3.5), "HotSpotY": NSNumber(value: 6),
            "PointsWide": NSNumber(value: 32), "PointsHigh": NSNumber(value: 32),
            "Representations": [makeFrames(32, 32, 8), makeFrames(64, 64, 8)],
        ]
        let recorder = RegistrationRecorder()
        let engine = recorder.engine()

        func apply(_ enabled: Bool, shadow: Bool = false, left: Bool = false, scale: Float = 1,
                   restore: Bool = false) -> Actions.Registration {
            recorder.calls.removeAll()
            let context = Actions.ApplyContext(identifiers: [id], shadow: shadow, leftHanded: left,
                                               renderScale: scale, padCursorCanvas: enabled)
            require(engine.applyCursor(cursor, identifier: id, restore: restore, context: context), "Registration failed")
            return recorder.calls.last(where: { $0.identifier == id })!
        }
        func compare(_ prior: Actions.Registration, _ current: Actions.Registration, expectedSize: CGFloat) {
            require(current.size == CGSize(width: expectedSize, height: expectedSize), "Registration size changed incorrectly")
            require(current.hotSpot == prior.hotSpot, "Hotspot moved")
            require(current.frameCount == prior.frameCount && current.frameDuration == prior.frameDuration, "Animation timing changed")
            require(current.images.count == prior.images.count, "Representation count changed")
            for (old, new) in zip(prior.images, current.images) {
                checkCanvas(old, new, frames: Int(prior.frameCount))
            }
        }

        let off = apply(false)
        let on = apply(true)
        compare(off, on, expectedSize: 96)
        require(on.images.map(\.width) == [96, 192], "1x/2x widths changed")
        require(recorder.calls.first(where: { $0.identifier == "com.apple.coregraphics.ArrowS" })?.size == on.size, "Alias differs")
        print("PASS byte-for-byte visible pixels, transparent margins and all 8 animation frames at 1x/2x; hotspot, duration and alias")

        compare(apply(false, shadow: true, left: true, scale: 0.75),
                apply(true, shadow: true, left: true, scale: 0.75), expectedSize: 72)
        require(apply(true, restore: true).size == off.size, "Default cursors were padded")
        recorder.rejectPadded = true
        require(apply(true).size == off.size && recorder.calls.filter { $0.identifier == id }.count == 2, "Registration did not fall back")
        recorder.rejectPadded = false
        print("PASS shadow plus left-handed mode and 0.75x scale; restore and failed registration fallback")

        let single = makeFrames(32, 32, 1)
        let staticCursor = ["FrameCount": 1, "FrameDuration": 1, "HotSpotX": 2, "HotSpotY": 3,
                            "PointsWide": 32, "PointsHigh": 32,
                            "Representations": [NSBitmapImageRep(cgImage: single).representation(using: .png, properties: [:])!]] as [String: Any]
        let theme = ["Identifier": "test", "Cursors": [id: staticCursor]] as NSDictionary
        func registerTheme() -> Actions.Registration {
            recorder.calls.removeAll()
            require(engine.applyTheme(theme), "Theme apply failed")
            return recorder.calls.first(where: { $0.identifier == id })!
        }
        require(registerTheme().size.width == 32, "Setting did not default off")
        recorder.options[MACPreferences.padCursorCanvasKey] = true
        let enabled = registerTheme()
        require(enabled.size.width == 96, "Preference did not turn padding on")
        checkCanvas(single, enabled.images.first!, frames: 1)
        recorder.isTahoe = false
        require(registerTheme().size.width == 32, "Older OS was padded")
        recorder.isTahoe = true
        recorder.options.removeAll()
        require(registerTheme().size.width == 32, "Turning the setting off did not restore the original size")
        print("PASS static PNG, preference off/on/off and pre-Tahoe guard through applyTheme")

        let workload = makeFrames(64, 64, 24)
        let theme28: [(CGImage, UInt)] = (0..<28).map { index in
            index < 26 ? (makeFrames(64, 64, 1), 1) : (workload, 24)
        }
        func medianThemeApply(_ padded: Bool) -> Double {
            let paddedContext = Actions.ApplyContext(identifiers: [], shadow: false, leftHanded: false,
                                                      renderScale: 1, padCursorCanvas: padded)
            let inputs = theme28.map { image, count -> [String: Any] in
                ["FrameCount": count, "FrameDuration": 0.1, "PointsWide": 32, "PointsHigh": 32,
                 "Representations": [image]]
            }
            let samples = (0..<7).map { _ in autoreleasepool {
                let start = ProcessInfo.processInfo.systemUptime
                for input in inputs {
                    recorder.calls.removeAll()
                    require(engine.applyCursor(input, identifier: "test", restore: false, context: paddedContext), "Benchmark apply failed")
                }
                return (ProcessInfo.processInfo.systemUptime - start) * 1000
            } }.sorted()
            return samples[samples.count / 2]
        }
        let base = medianThemeApply(false)
        let padded = medianThemeApply(true)
        print(String(format: "28 cursors, 2x, including two 24-frame animations, median of 7 runs: off %.2f ms, on %.2f ms", base, padded))
        let large = makeFrames(320, 320, 24)
        let start = ProcessInfo.processInfo.systemUptime
        let high = Actions.paddedCursorCanvas([large], frameCount: 24, pointSize: CGSize(width: 32, height: 32))!.images[0]
        require(high.width == 960 && high.height == 960 * 24, "10x animation dimensions incorrect")
        print(String(format: "10x 24-frame canvas: %.2f MiB raw destination, %.2f ms",
                     Double(high.width * high.height * 4) / 1_048_576, (ProcessInfo.processInfo.systemUptime - start) * 1000))
    }
}
