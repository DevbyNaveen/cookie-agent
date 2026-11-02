import AppKit
import SwiftUI

/// A key-capable writing panel without NSPopover's outline and arrow.
struct MemoryPanelAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.presented = $isPresented
        context.coordinator.anchor = view
        if isPresented {
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard let coordinator, coordinator.presented?.wrappedValue == true else { return }
                coordinator.show(model: model)
            }
        } else { context.coordinator.close() }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator: NSObject {
        weak var anchor: NSView?
        var presented: Binding<Bool>?
        private var panel: MemoryPanel?
        private var localMonitor: Any?
        private var globalMonitor: Any?
        private var screenObserver: NSObjectProtocol?

        func show(model: AppModel) {
            guard panel == nil, let owner = anchor?.window else { return }
            let window = MemoryPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = owner.level
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.animationBehavior = .none
            let content = MemoryPanelReveal {
                QuickMemoryView(dismiss: { [weak self] in self?.dismiss() })
                    .environmentObject(model)
            }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    self?.place(size: size)
                }
            let hosting = NSHostingView(rootView: content)
            panel = window
            window.contentView = hosting
            place(size: hosting.fittingSize)
            owner.addChildWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismiss(); return nil }
                } else { self.dismissIfOutside() }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismissIfOutside()
            }
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }

        private func place(size: CGSize) {
            guard let panel, let anchor, let owner = anchor.window,
                  size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            let rect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let visible = (owner.screen ?? NSScreen.main)?.visibleFrame ?? owner.frame
            let width = min(size.width, visible.width - 24)
            let height = min(size.height, visible.height - 24)
            let x = min(max(rect.midX - width / 2, visible.minX + 12), visible.maxX - width - 12)
            let y = min(max(rect.maxY + 14, visible.minY + 12), visible.maxY - height - 12)
            let frame = NSRect(x: x, y: y, width: width, height: height)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }

        private func dismissIfOutside() {
            guard let panel else { return }
            let point = NSEvent.mouseLocation
            if panel.frame.contains(point) { return }
            // The Memory button handles its own toggle, so don't toggle twice.
            if let anchor, let owner = anchor.window,
               owner.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(point) { return }
            dismiss()
        }

        private func dismiss() {
            presented?.wrappedValue = false
            close()
        }

        func close() {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            localMonitor = nil; globalMonitor = nil; screenObserver = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                panel.close()
            }
            panel = nil
        }
    }
}

private final class MemoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Animate the surface and its contents together, without resizing/reflowing the window.
private struct MemoryPanelReveal<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .scaleEffect(expanded || reduceMotion ? 1 : 0.18, anchor: .bottom)
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.38, bounce: 0.08)) {
                    expanded = true
                }
            }
    }
}
