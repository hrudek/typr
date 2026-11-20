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

    private func returnKeyFace(in image: UIImage) -> UIColor {
        let point = CGPoint(x: image.size.width - 10 - 56 + 9, y: image.size.height - 6 - 21)
        guard let data = image.cgImage?.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              let cg = image.cgImage else { return .clear }
        let offset = Int(point.y) * cg.bytesPerRow + Int(point.x) * cg.bitsPerPixel / 8
        let isBGRA = cg.bitmapInfo.contains(.byteOrder32Little)
        let r = CGFloat(bytes[offset + (isBGRA ? 2 : 0)]) / 255
        let g = CGFloat(bytes[offset + 1]) / 255
        let b = CGFloat(bytes[offset + (isBGRA ? 0 : 2)]) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
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

    func testStandardDesignDrawsFullKeyboardKeyFill() {
        let model = KeyboardViewModel()
        model.keyDesign = .standard
        assertClose(returnKeyFace(in: render(model)), FullKeyboardPalette(isDark: true).keyFill)
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
