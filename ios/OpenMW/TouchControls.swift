// The touch controls: Melo-Controller's on-screen controller over SDL's game view. apps/openmw/ios/platform.mm decides
// when they show and turns their presses into an SDL virtual game controller.

import Observation
import SwiftUI
import UIKit
@preconcurrency import MeloController

/// A press (true) or release of a Melo button: "A", "leftTrigger", "dPadUp", ...
typealias TouchButton = @convention(c) (UnsafePointer<CChar>, Bool) -> Void
/// A stick position: right stick, x and y in -1...1 (y down)
typealias TouchStick = @convention(c) (Bool, Float, Float) -> Void

/// The labels of the Settings app's "Button Labels" (platform.mm's order) by Melo button id: symbol and the name the
/// layout editor shows. Melo's ids name its Nintendo positions: X top, Y left, A right, B bottom.
private let labelStyles: [[String: (icon: String, name: String)]] = [
    // Xbox
    [
        "X": ("y.circle.fill", "Y"), "Y": ("x.circle.fill", "X"), "A": ("b.circle.fill", "B"),
        "B": ("a.circle.fill", "A"), "leftShoulder": ("lb.rectangle.roundedbottom.fill", "LB"),
        "rightShoulder": ("rb.rectangle.roundedbottom.fill", "RB"),
        "leftTrigger": ("lt.rectangle.roundedtop.fill", "LT"), "rightTrigger": ("rt.rectangle.roundedtop.fill", "RT"),
        "back": ("rectangle.on.rectangle.circle.fill", "View"), "start": ("line.3.horizontal.circle.fill", "Menu"),
    ],
    // PlayStation
    [
        "X": ("triangle.circle.fill", "Triangle"), "Y": ("square.circle.fill", "Square"),
        "A": ("circle.circle.fill", "Circle"), "B": ("xmark.circle.fill", "Cross"),
        "leftShoulder": ("l1.rectangle.roundedbottom.fill", "L1"),
        "rightShoulder": ("r1.rectangle.roundedbottom.fill", "R1"),
        "leftTrigger": ("l2.rectangle.roundedtop.fill", "L2"), "rightTrigger": ("r2.rectangle.roundedtop.fill", "R2"),
        "back": ("square.and.arrow.up.circle.fill", "Share"), "start": ("line.3.horizontal.circle.fill", "Options"),
    ],
    // Nintendo: Melo's own
    [:],
]

private final class TouchInput: Controller {
    let button: TouchButton
    let stick: TouchStick

    init(button: TouchButton, stick: TouchStick) {
        self.button = button
        self.stick = stick
    }

    func buttonPressed(_ pressed: VirtualControllerButton) { pressed.id.withCString { button($0, true) } }
    func buttonReleased(_ released: VirtualControllerButton) { released.id.withCString { button($0, false) } }
    func joystickMoved(position: CGPoint, right: Bool) { stick(right, Float(position.x), Float(position.y)) }
}

/// Melo's layout editor: offered while the game menu is the top screen (platform.mm), open while editing.
@MainActor @Observable private final class EditState {
    var editable = false
    var editing = false
}

/// A UIKit button: SwiftUI's own controls are part of the hosting view, whose touches go on to the game.
private struct EditButton: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(systemName: "pencil")
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = "Edit Touch Controls"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}

private struct TouchControlsRoot: View {
    let input: TouchInput
    let state: EditState

    var body: some View {
        ZStack(alignment: .topLeading) {
            ControllerView(controller: input, isEditing: state.editing, onEditingChanged: { state.editing = $0 })
            if state.editable && !state.editing {
                EditButton { state.editing = true }
                    .frame(width: 44, height: 44)
                    .padding(12)
            }
        }
    }
}

/// Holds the controller over SDL's view controller's view: touches outside the controls go on to the game, all go to
/// the layout editor while it is open. SDL replaces that view when it creates the GL context (its Metal view), which
/// takes this view out of the window: it follows to the new one.
private final class TouchControlsView: UIView {
    weak var gameWindow: UIWindow?
    var state: EditState?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if state?.editing == true {
            return view
        }
        return view === self || view === subviews.first ? nil : view
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
    }

    func attach() {
        guard let gameView = gameWindow?.rootViewController?.view, superview !== gameView else { return }
        frame = gameView.bounds
        gameView.addSubview(self)
    }
}

@MainActor private var touchControls:
    (host: UIHostingController<TouchControlsRoot>, view: TouchControlsView, state: EditState)?

/// Shows the controller over the game view of \a window (SDL's UIWindow) with the labels of \a style; presses and
/// stick positions go to \a button and \a stick. Called on the main thread.
@MainActor @_cdecl("OMWShowTouchControls")
func showTouchControls(
    _ window: UnsafeMutableRawPointer, _ style: Int32, _ button: TouchButton, _ stick: TouchStick
) {
    hideTouchControls()
    let gameWindow = Unmanaged<UIWindow>.fromOpaque(window).takeUnretainedValue()
    guard let viewController = gameWindow.rootViewController else { return }

    let labels = labelStyles.indices.contains(Int(style)) ? labelStyles[Int(style)] : [:]
    VirtualControllerButton.iconOverrides = labels.mapValues { $0.icon }
    VirtualControllerButton.nameOverrides = labels.mapValues { $0.name }
    // L3 (sneak) and R3 (first/third person view); each can be hidden in the layout editor
    UserDefaults.standard.register(defaults: ["stickButton": true])
    LayoutExporter.directory = URL.documentsDirectory.appending(path: "Config/Controller", directoryHint: .isDirectory)

    let state = EditState()
    let host = UIHostingController(
        rootView: TouchControlsRoot(input: TouchInput(button: button, stick: stick), state: state))
    host.view.backgroundColor = .clear
    let view = TouchControlsView()
    view.state = state
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    view.gameWindow = gameWindow
    viewController.addChild(host)
    view.attach()
    host.didMove(toParent: viewController)
    touchControls = (host, view, state)
}

/// Shows the layout editor's button (the game menu is the top screen) or hides it.
@MainActor @_cdecl("OMWSetTouchControlsEditable")
func setTouchControlsEditable(_ editable: Bool) {
    touchControls?.state.editable = editable
}

@MainActor @_cdecl("OMWHideTouchControls")
func hideTouchControls() {
    guard let controls = touchControls else { return }
    touchControls = nil
    controls.view.gameWindow = nil
    controls.host.willMove(toParent: nil)
    controls.view.removeFromSuperview()
    controls.host.removeFromParent()
}
