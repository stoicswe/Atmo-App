import SwiftUI
#if os(iOS)
import PencilKit
import UIKit

// MARK: - Drawing Sheet
/// PencilKit canvas with the system tool picker. Done hands back a PNG
/// of the drawing on a white ground, ready to attach like any photo.
struct DrawingSheet: View {
    let onDone: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            DrawingCanvas(drawing: $drawing)
                .background(Color.white)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Drawing")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Done") {
                            if let data = Self.render(drawing, in: canvasSize) {
                                Haptics.confirm()
                                onDone(data)
                            }
                            dismiss()
                        }
                        .disabled(drawing.strokes.isEmpty)
                    }
                }
        }
    }

    /// Composites the strokes over white at 2× and encodes PNG. Uses the
    /// canvas bounds so the exported image keeps the aspect drawn in.
    static func render(_ drawing: PKDrawing, in size: CGSize) -> Data? {
        guard !drawing.strokes.isEmpty else { return nil }
        let bounds = size.width > 0 && size.height > 0
            ? CGRect(origin: .zero, size: size)
            : drawing.bounds.insetBy(dx: -24, dy: -24)
        let strokes = drawing.image(from: bounds, scale: 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            strokes.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
        return image.pngData()
    }
}

private struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.backgroundColor = .white
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        context.coordinator.toolPicker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.toolPicker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        private let drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) { self.drawing = drawing }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}
#endif
