import ReplayKit
import SwiftUI
import XCTest
@testable import XiangqiCoach

@MainActor
final class BroadcastPickerTests: XCTestCase {
    func testSystemPickerRetainsExtensionAndNativeTargetsAcrossUpdates() throws {
        let picker = makePicker()
        let button = try XCTUnwrap(picker.broadcastButton)
        let original = registrations(on: button, excludingPreparation: true)
        XCTAssertFalse(original.isEmpty, "必须保留 ReplayKit 原生确认事件")
        for index in 0..<8 {
            picker.update(title: "开始 \(index)", isEnabled: index.isMultiple(of: 2), onTap: {})
            picker.frame.size = CGSize(width: 220 + index * 10, height: 68)
            picker.layoutIfNeeded()
        }
        XCTAssertEqual(picker.preferredExtension, BroadcastPickerView.extensionBundleIdentifier)
        XCTAssertFalse(picker.showsMicrophoneButton)
        XCTAssertTrue(picker.broadcastButton === button)
        XCTAssertEqual(registrations(on: button, excludingPreparation: true), original)
        XCTAssertEqual(preparationHandlerCount(on: button), 1)
        XCTAssertEqual(button.configuration?.title, "开始 7")
        XCTAssertEqual(button.configuration?.background.cornerRadius, 0)
        XCTAssertEqual(button.layer.cornerRadius, 0)
    }

    func testTouchPreparationRunsOnceBeforeNativeReleaseEvent() throws {
        let picker = makePicker()
        let button = try XCTUnwrap(picker.broadcastButton)
        var events: [String] = []
        let nativeEvent = replaceSystemActivation(on: button) { events.append("system-confirmation") }
        picker.update(title: "开始", isEnabled: true) { events.append("prepare") }
        // 测试先移除系统 presentation handler 并接记录器；绝不打开授权页或开始录屏。
        button.sendActions(for: .touchDown)
        XCTAssertEqual(events, ["prepare"])
        button.sendActions(for: nativeEvent)
        XCTAssertEqual(events, ["prepare", "system-confirmation"])
    }

    func testUpdateUsesLatestCallbackWithoutDuplicateBindings() throws {
        let picker = makePicker()
        let button = try XCTUnwrap(picker.broadcastButton)
        var oldCalls = 0
        var newCalls = 0
        picker.update(title: "旧标题", isEnabled: true) { oldCalls += 1 }
        for _ in 0..<10 {
            picker.update(title: "开始", isEnabled: true) { newCalls += 1 }
        }
        XCTAssertEqual(preparationHandlerCount(on: button), 1)
        // touchDown 仅准备；没有发送打开 ReplayKit 确认页的事件。
        button.sendActions(for: .touchDown)
        XCTAssertEqual(oldCalls, 0)
        XCTAssertEqual(newCalls, 1)
        XCTAssertEqual(button.configuration?.title, "开始")
    }

    func testVoiceOverActivationPreparesBeforeNativeEventExactlyOnce() throws {
        let picker = makePicker()
        let button = try XCTUnwrap(picker.broadcastButton)
        var events: [String] = []
        _ = replaceSystemActivation(on: button) { events.append("system-confirmation") }
        picker.update(title: "开始", isEnabled: true) { events.append("prepare") }
        XCTAssertTrue(picker.isAccessibilityElement)
        XCTAssertFalse(button.isAccessibilityElement)
        XCTAssertTrue(button.accessibilityElementsHidden)
        XCTAssertEqual(picker.accessibilityIdentifier, "coach.start")
        XCTAssertEqual(picker.accessibilityLabel, "开始")
        XCTAssertEqual(picker.accessibilityHint, "打开系统录屏确认页")
        XCTAssertTrue(picker.accessibilityTraits.contains(.button))
        XCTAssertFalse(picker.accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(picker.accessibilityActivate())
        XCTAssertEqual(events, ["prepare", "system-confirmation"])
    }

    func testDisabledPickerBlocksTouchAndAccessibilityAndCanBeEnabledAgain() throws {
        let picker = makePicker()
        let button = try XCTUnwrap(picker.broadcastButton)
        var prepared = 0
        var opened = 0
        _ = replaceSystemActivation(on: button) { opened += 1 }
        picker.update(title: "准备中", isEnabled: false) { prepared += 1 }
        picker.layoutIfNeeded()
        XCTAssertFalse(button.isEnabled)
        XCTAssertFalse(picker.isUserInteractionEnabled)
        XCTAssertNil(picker.hitTest(CGPoint(x: 110, y: 32), with: nil))
        XCTAssertTrue(picker.accessibilityTraits.contains(.notEnabled))
        button.sendActions(for: .touchDown)
        XCTAssertFalse(picker.accessibilityActivate())
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(opened, 0)

        picker.update(title: "开始", isEnabled: true) { prepared += 1 }
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(picker.accessibilityActivate())
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(opened, 1)
    }

    func testAccessibilityDoesNotForwardIfPreparationDisablesButton() throws {
        let picker = makePicker()
        let button = try XCTUnwrap(picker.broadcastButton)
        var opened = 0
        _ = replaceSystemActivation(on: button) { opened += 1 }
        picker.update(title: "开始", isEnabled: true) { [weak picker] in
            picker?.update(title: "准备中", isEnabled: false, onTap: {})
        }
        XCTAssertFalse(picker.accessibilityActivate())
        XCTAssertEqual(opened, 0)
    }

    func testHostedPickerAdaptsToDynamicSizeAndEntireButtonIsHittable() async throws {
        let fixture = try await mountedPicker(size: CGSize(width: 220, height: 68))
        defer { fixture.close() }
        let picker = fixture.picker
        let button = try XCTUnwrap(picker.broadcastButton)
        for size in [CGSize(width: 220, height: 68), CGSize(width: 360, height: 64), CGSize(width: 160, height: 96)] {
            // 与首页一致：完整屏幕窗口中给 picker 一个明确 frame；窗口自身仍保留系统安全区。
            fixture.host.rootView = PickerTestRoot(size: size)
            fixture.host.view.setNeedsLayout()
            for _ in 0..<20 {
                fixture.host.view.layoutIfNeeded()
                picker.layoutIfNeeded()
                if picker.bounds.size == size { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(picker.bounds.size, size)
            XCTAssertEqual(button.frame, picker.bounds)
            XCTAssertTrue(button.frame.origin.x.isFinite)
            XCTAssertTrue(button.frame.origin.y.isFinite)
            for point in [CGPoint(x: 1, y: 1), CGPoint(x: size.width - 1, y: 1),
                          CGPoint(x: 1, y: size.height - 1), CGPoint(x: size.width - 1, y: size.height - 1),
                          CGPoint(x: size.width / 2, y: size.height / 2)] {
                XCTAssertTrue(picker.hitTest(point, with: nil) === button, "\(size) 的 \(point) 必须命中原生按钮")
            }
            XCTAssertNil(picker.hitTest(CGPoint(x: size.width + 1, y: size.height / 2), with: nil))
        }
    }

    private func makePicker() -> PreparedBroadcastPickerView {
        let picker = PreparedBroadcastPickerView(frame: CGRect(origin: .zero, size: BroadcastPickerView.preferredSize))
        picker.layoutIfNeeded()
        return picker
    }

    private func preparationHandlerCount(on button: UIButton) -> Int {
        var count = 0
        button.enumerateEventHandlers { action, _, _, _ in
            if action?.identifier == PreparedBroadcastPickerView.preparationActionIdentifier { count += 1 }
        }
        return count
    }

    private func registrations(on button: UIButton, excludingPreparation: Bool) -> Set<String> {
        var result = Set<String>()
        button.enumerateEventHandlers { action, targetAction, events, _ in
            if let action {
                if excludingPreparation && action.identifier == PreparedBroadcastPickerView.preparationActionIdentifier { return }
                result.insert("action:\(action.identifier.rawValue):\(events.rawValue)")
            }
            if let (target, selector) = targetAction {
                let identity = target.map { String(describing: ObjectIdentifier($0 as AnyObject)) } ?? "responder-chain"
                result.insert("target:\(identity):\(NSStringFromSelector(selector)):\(events.rawValue)")
            }
        }
        return result
    }

    /// 仅测试 fixture 移除系统处理器；生产代码始终保留它们。记录器代替展示授权，避免测试启动录屏。
    private func replaceSystemActivation(on button: UIButton, action: @escaping () -> Void) -> UIControl.Event {
        let nativeEvent: UIControl.Event = button.allControlEvents.contains(.touchUpInside) ? .touchUpInside : .primaryActionTriggered
        var removals: [() -> Void] = []
        button.enumerateEventHandlers { handler, targetAction, events, _ in
            if let handler, handler.identifier != PreparedBroadcastPickerView.preparationActionIdentifier {
                removals.append { button.removeAction(handler, for: events) }
            }
            if let (target, selector) = targetAction {
                removals.append { button.removeTarget(target, action: selector, for: events) }
            }
        }
        removals.forEach { $0() }
        button.addAction(UIAction { _ in action() }, for: nativeEvent)
        return nativeEvent
    }

    /// 页面占满屏幕，内部按钮显式定宽高，复现 ContentView 的真实承载方式。
    private struct PickerTestRoot: View {
        let size: CGSize
        var body: some View {
            BroadcastPickerView()
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @MainActor
    private struct MountedPicker {

        let host: UIHostingController<PickerTestRoot>
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let picker: PreparedBroadcastPickerView
        func close() { window.isHidden = true; previousKeyWindow?.makeKey() }
    }

    private func mountedPicker(size: CGSize) async throws -> MountedPicker {
        let host = UIHostingController(rootView: PickerTestRoot(size: size))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<20 {
            host.view.layoutIfNeeded()
            if let picker = findPicker(in: host.view) {
                return MountedPicker(host: host, window: window, previousKeyWindow: previousKeyWindow, picker: picker)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        window.isHidden = true
        previousKeyWindow?.makeKey()
        throw XCTUnwrapFailure()
    }

    private func findPicker(in view: UIView) -> PreparedBroadcastPickerView? {
        if let picker = view as? PreparedBroadcastPickerView { return picker }
        return view.subviews.lazy.compactMap { self.findPicker(in: $0) }.first
    }

    private struct XCTUnwrapFailure: Error {}
}
