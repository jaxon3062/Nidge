import NidgeKit
import SwiftUI

/// One photo at a time, swiping between them, like Photos.
struct PhotoViewer: View {
    @Environment(AppModel.self) private var model
    @State var current: String

    var body: some View {
        let items = model.visibleItems
        TabView(selection: $current) {
            ForEach(items) { item in
                PhotoPage(item: item).tag(item.key)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(.systemBackground))
        .navigationTitle(items.first { $0.key == current }?.filename ?? "")
        .navigationSubtitle(items.first { $0.key == current }.map { Self.date($0.captureDate) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let item = items.first(where: { $0.key == current }), model.isImported(item) {
                ToolbarItem(placement: .topBarTrailing) {
                    Label("Imported", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
    }

    private static func date(_ stamp: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyyMMdd'T'HHmmss"
        return parser.date(from: stamp)?.formatted(date: .abbreviated, time: .shortened) ?? stamp
    }
}

private struct PhotoPage: View {
    @Environment(AppModel.self) private var model
    let item: PhotoItem
    @State private var thumbnail: UIImage?
    @State private var full: UIImage?
    @State private var loading = true

    var body: some View {
        ZStack {
            if let image = full ?? thumbnail {
                Image(uiImage: image).resizable().scaledToFit()
            }
            if loading { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(item.filename)
        .task(id: model.isConnected) {
            guard full == nil else { return }
            loading = true
            if thumbnail == nil { thumbnail = await model.thumbnail(for: item) }
            full = await model.preview(for: item)
            loading = false
        }
    }
}
