import SwiftUI
import XCTest
@testable import Typr

@MainActor
final class DictationKeyStyleTests: XCTestCase {
    private func render(_ model: KeyboardViewModel, host: UIHostingController<KeyboardSurfaceView>? = nil) -> UIImage {
        let host = host ?? UIHostingController(rootView: KeyboardSurfaceView(model: model))
        let size = CGSize(width: 393, height: host.sizeThatFits(in: CGSize(width: 393, height: 1_000)).height)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    private func keycaps(in view: UIView) -> [Keycap.KeycapView] {
        view.subviews.flatMap { subview -> [Keycap.KeycapView] in
            if let keycap = subview as? Keycap.KeycapView { return [keycap] }
            return keycaps(in: subview)
        }
    }

    private func color(at point: CGPoint, in image: UIImage) throws -> UIColor {
        let pixel = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: Int(point.x), y: Int(point.y), width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return UIColor(red: CGFloat(rgba[0]) / 255, green: CGFloat(rgba[1]) / 255, blue: CGFloat(rgba[2]) / 255, alpha: 1)
    }

    private func assertClose(_ a: UIColor, _ b: UIColor, file: StaticString = #filePath, line: UInt = #line) {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        XCTAssertEqual(ar, br, accuracy: 3.0 / 255, file: file, line: line)
        XCTAssertEqual(ag, bg, accuracy: 3.0 / 255, file: file, line: line)
        XCTAssertEqual(ab, bb, accuracy: 3.0 / 255, file: file, line: line)
    }

    func testStandardDesignDrawsFullKeyboardKeyFill() throws {
        let model = KeyboardViewModel()
        model.keyDesign = .standard
        let host = UIHostingController(rootView: KeyboardSurfaceView(model: model))
        let image = render(model, host: host)
        let caps = keycaps(in: host.view)
        XCTAssertFalse(caps.isEmpty)
        for cap in caps {
            let face = cap.bounds.insetBy(dx: Keycap.shadowOverhang, dy: Keycap.shadowOverhang)
            let point = cap.convert(CGPoint(x: face.minX + FullKeyboardPalette.cornerRadius, y: face.midY), to: host.view)
            XCTAssertTrue(CGRect(origin: .zero, size: image.size).contains(point))
            assertClose(try color(at: point, in: image), FullKeyboardPalette(isDark: true).keyFill)
        }
    }

    func testDesignChangeRedrawsMountedKeys() {
        let model = KeyboardViewModel()
        let host = UIHostingController(rootView: KeyboardSurfaceView(model: model))
        let standard = render(model, host: host).pngData()
        model.keyDesign = .mechanical
        let mechanical = render(model, host: host).pngData()
        XCTAssertNotEqual(mechanical, standard)
    }
}
