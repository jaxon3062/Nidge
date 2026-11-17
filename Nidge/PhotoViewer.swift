import NidgeKit
import SwiftUI

/// One photo at a time, swiping between them, like Photos.
struct PhotoViewer: View {
    @Environment(AppModel.self) private var model
    @State var current: String

    var body: some View {
        let items = model.visibleItems
        TabView(selection: $current) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                PhotoPage(item: item, isCurrent: item.key == current,
                          neighbors: [index + 1, index - 1].filter(items.indices.contains).map { items[$0] })
                    .tag(item.key)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(.systemBackground))
        .navigationTitle(items.first { $0.key == current }?.filename ?? "")
        .navigationSubtitle(items.first { $0.key == current }.map { Self.date($0.captureDate) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.viewerOpen = true }
        .onDisappear { model.viewerOpen = false }
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
    let isCurrent: Bool
    /// Fetched after this photo is done, so a swipe to either side is instant.
    let neighbors: [PhotoItem]
    @State private var image: UIImage?
    @State private var sharp = false
    @State private var loading = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            }
            if loading { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(item.filename)
        // Only the photo on screen loads; swiping away cancels what it was fetching.
        .task(id: "\(model.isConnected) \(isCurrent)") {
            if image == nil { image = await model.thumbnail(for: item) }
            guard isCurrent else { return }
            if !sharp {
                loading = true
                if let quick = await model.quickPreview(for: item) { image = quick }
                if let full = await model.preview(for: item) { image = full; sharp = true }
                loading = false
            }
            for neighbor in neighbors where !Task.isCancelled { _ = await model.quickPreview(for: neighbor) }
            for neighbor in neighbors where !Task.isCancelled { _ = await model.preview(for: neighbor) }
        }
    }
}
