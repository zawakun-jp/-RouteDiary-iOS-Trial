import SwiftUI
import UIKit

/// Android版の「移動・拡大縮小・十字ガイド付き正方形トリミング」に対応。
struct AvatarCropView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let onSave: (Data) -> Void
    @State private var scale: CGFloat = 1
    @State private var storedScale: CGFloat = 1
    @State private var displacement: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @State private var previewSide: CGFloat = 280

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("画像を指で動かし、ピンチして拡大縮小できます。十字ガイド内の正方形が保存されます。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    let base = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
                    ZStack {
                        Color.black
                        Image(uiImage: image).resizable().interpolation(.high)
                            .frame(width: image.size.width * base, height: image.size.height * base)
                            .scaleEffect(scale)
                            .offset(x: displacement.width + drag.width, y: displacement.height + drag.height)
                        Rectangle().stroke(Color.white, lineWidth: 2)
                        Path { path in
                            path.move(to: CGPoint(x: side / 2, y: 0))
                            path.addLine(to: CGPoint(x: side / 2, y: side))
                            path.move(to: CGPoint(x: 0, y: side / 2))
                            path.addLine(to: CGPoint(x: side, y: side / 2))
                        }.stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    }
                    .frame(width: side, height: side).clipped()
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            displacement.width += value.translation.width
                            displacement.height += value.translation.height
                        })
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { zoom in scale = max(1, min(5, storedScale * zoom)) }
                        .onEnded { _ in storedScale = scale })
                    .onAppear { previewSide = side }
                    .onChange(of: side) { _, next in previewSide = next }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .aspectRatio(1, contentMode: .fit)
                Button("中央に戻す") { scale = 1; storedScale = 1; displacement = .zero }
                    .buttonStyle(.bordered)
                Spacer(minLength: 4)
            }
            .padding(14)
            .navigationTitle("アイコン画像をトリミング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let jpeg = cropJPEG() { onSave(jpeg); dismiss() }
                    }
                }
            }
        }
    }

    private func cropJPEG() -> Data? {
        let canvas: CGFloat = 512
        let factor = max(canvas / max(image.size.width, 1), canvas / max(image.size.height, 1)) * scale
        let width = image.size.width * factor, height = image.size.height * factor
        let adjust = canvas / max(previewSide, 1)
        let cropRect = CGRect(x: (canvas - width) / 2 + displacement.width * adjust,
                              y: (canvas - height) / 2 + displacement.height * adjust,
                              width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas))
        let output = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
            image.draw(in: cropRect)
        }
        return output.jpegData(compressionQuality: 0.82)
    }
}
