import ReplayKit
import SwiftUI
import XCTest
@testable import XiangqiCoach

final class BroadcastPickerTests: XCTestCase {
    @MainActor
    func testSystemPickerHasNonEmptyButtonHitArea() async throws {
        let host = UIHostingController(rootView: BroadcastPickerView())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 54, height: 54)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        // UIViewRepresentable 在实际挂载后才创建原生控件；等待一次真实布局，避免测到空 HostingView。
        for _ in 0..<20 {
            host.view.layoutIfNeeded()
            if findPicker(in: host.view) != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let picker = try XCTUnwrap(findPicker(in: host.view))
        XCTAssertEqual(picker.preferredExtension, BroadcastPickerView.extensionBundleIdentifier)
        let button = try XCTUnwrap(picker.subviews.compactMap { $0 as? UIButton }.first)
        XCTAssertGreaterThan(button.bounds.width, 0)
        XCTAssertGreaterThan(button.bounds.height, 0)
        XCTAssertNotNil(picker.hitTest(CGPoint(x: 27, y: 27), with: nil))
    }

    private func findPicker(in view: UIView) -> RPSystemBroadcastPickerView? {
        if let picker = view as? RPSystemBroadcastPickerView { return picker }
        return view.subviews.lazy.compactMap { self.findPicker(in: $0) }.first
    }
}
