import AppKit
import SwiftUI
import EdgeModel

private enum CanvasResizeHandle: String, CaseIterable, Identifiable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var adjustsLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var adjustsRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var adjustsTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var adjustsBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var corner: Bool { (adjustsLeft || adjustsRight) && (adjustsTop || adjustsBottom) }
    var label: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
    var cursor: NSCursor {
        corner ? .crosshair : (adjustsLeft || adjustsRight ? .resizeLeftRight : .resizeUpDown)
    }
    func position(in center: CGRect) -> CGPoint {
        CGPoint(x: adjustsLeft ? center.minX : adjustsRight ? center.maxX : center.midX,
                y: adjustsTop ? center.minY : adjustsBottom ? center.maxY : center.midY)
    }
}

struct TrackpadCanvas: View {
    @ObservedObject var model: AppModel
    @State private var resizeOrigin: Margins?
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGRect(x: size.width * model.margins.left, y: size.height * model.margins.top,
                width: size.width * (1 - model.margins.left - model.margins.right),
                height: size.height * (1 - model.margins.top - model.margins.bottom))
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.12))
                Path { $0.addRect(center) }.fill(Color.green.opacity(0.16))
                Path { $0.addRect(center) }.stroke(Color.green.opacity(0.6), lineWidth: 1)
                Text("CENTER").font(.caption).foregroundStyle(.secondary)
                    .position(x: center.midX, y: center.midY).allowsHitTesting(false)
                ForEach(model.contacts) { contact in
                    let color: Color = !contact.active ? .gray : model.margins.contains(contact) ? .green : .red
                    ZStack {
                        Circle().fill(color.opacity(model.fresh ? 0.9 : 0.25)).frame(width: 24, height: 24)
                        Text("\(contact.id)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }.position(x: size.width * contact.x, y: size.height * (1 - contact.y))
                        .allowsHitTesting(false)
                }
                ForEach(CanvasResizeHandle.allCases) { handle in
                    resizeHandle(handle, center: center, size: size)
                }
            }
            .coordinateSpace(name: "trackpadCanvas")
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.gray.opacity(0.4)).allowsHitTesting(false))
        }
        .frame(height: 250)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trackpad canvas. Drag the green edges or corners to resize the center.")
    }
    private func resizeHandle(_ handle: CanvasResizeHandle, center: CGRect, size: CGSize) -> some View {
        let vertical = handle.adjustsLeft || handle.adjustsRight
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.green)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.85), lineWidth: 1))
            .frame(width: handle.corner ? 12 : vertical ? 6 : 24,
                   height: handle.corner ? 12 : vertical ? 24 : 6)
            .frame(width: handle.corner || vertical ? 24 : max(24, center.width - 24),
                   height: handle.corner || !vertical ? 24 : max(24, center.height - 24))
            .contentShape(Rectangle())
            .onHover { inside in (inside ? handle.cursor : NSCursor.arrow).set() }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trackpadCanvas"))
                .onChanged { drag in
                    guard size.width > 0, size.height > 0 else { return }
                    if resizeOrigin == nil { resizeOrigin = model.margins }
                    let origin = resizeOrigin ?? model.margins
                    resize(handle, origin: origin,
                           dx: drag.translation.width / size.width, dy: drag.translation.height / size.height)
                }
                .onEnded { _ in resizeOrigin = nil })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize \(handle.label.lowercased()) margin")
            .accessibilityAdjustableAction { direction in
                let step: Double
                switch direction {
                case .increment: step = 0.01
                case .decrement: step = -0.01
                @unknown default: return
                }
                resize(handle, origin: model.margins,
                       dx: handle.adjustsRight ? -step : step, dy: handle.adjustsBottom ? -step : step)
            }
            .help("Drag to resize the \(handle.label.lowercased()) margin")
            .position(handle.position(in: center))
    }
    private func resize(_ handle: CanvasResizeHandle, origin: Margins, dx: Double, dy: Double) {
        func percent(_ value: Double) -> Double { min(0.45, max(0, (value * 100).rounded() / 100)) }
        let margins = Margins(
            left: handle.adjustsLeft ? percent(origin.left + dx) : origin.left,
            right: handle.adjustsRight ? percent(origin.right - dx) : origin.right,
            top: handle.adjustsTop ? percent(origin.top + dy) : origin.top,
            bottom: handle.adjustsBottom ? percent(origin.bottom - dy) : origin.bottom)
        if margins != model.margins { model.margins = margins }
    }
}

struct MarginControl: View {
    let name: String
    @Binding var value: Double
    @State private var percentText = ""
    @FocusState private var editingPercent: Bool
    private var displayedPercent: String { String(Int((value * 100).rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(name).font(.caption)
                Spacer(minLength: 4)
                TextField("0", text: $percentText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .focused($editingPercent)
                    .accessibilityLabel("\(name) margin percentage")
                    .onSubmit(commitPercentage)
                Text("%").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...0.45, step: 0.01)
                .accessibilityLabel("\(name) margin")
        }
        .onAppear { percentText = displayedPercent }
        .onChange(of: value) { _, _ in percentText = displayedPercent }
        .onChange(of: percentText) { _, text in
            guard editingPercent, let number = Int(text.trimmingCharacters(in: .whitespaces)),
                  (0...45).contains(number) else { return }
            let margin = Double(number) / 100
            if value != margin { value = margin }
        }
        .onChange(of: editingPercent) { _, editing in if !editing { commitPercentage() } }
    }
    private func commitPercentage() {
        if let number = Int(percentText.trimmingCharacters(in: .whitespaces)) {
            let margin = Double(min(45, max(0, number))) / 100
            if value != margin { value = margin }
        }
        percentText = displayedPercent
    }
}
