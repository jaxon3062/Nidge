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
    /// The file the image comes from: the photo, or a RAW file's JPEG/HEIF twin.
    @State private var shown: PhotoItem?
    @State private var sharp = false
    @State private var loading = false
    @State private var fullResolution: Task<Void, Never>?
    @State private var isFullResolution = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image) { loadFullResolution() }
            }
            if loading { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(item.filename)
        // Only the photo on screen loads; swiping away cancels what it was fetching.
        .task(id: "\(model.isConnected) \(isCurrent)") {
            if image == nil { image = await model.thumbnail(for: item) }
            guard isCurrent else {
                fullResolution?.cancel()
                // Let go of a 24 MP image once it is off screen.
                if isFullResolution, let shown, let preview = await model.preview(for: shown) {
                    image = preview
                    isFullResolution = false
                }
                return
            }
            let target = await model.viewable(item)
            shown = target
            if !sharp {
                loading = true
                if let quick = await model.quickPreview(for: target) { image = quick }
                if let full = await model.preview(for: target) { image = full; sharp = true }
                loading = false
            }
            for neighbor in neighbors where !Task.isCancelled {
                _ = await model.quickPreview(for: await model.viewable(neighbor))
            }
            for neighbor in neighbors where !Task.isCancelled {
                _ = await model.preview(for: await model.viewable(neighbor))
            }
        }
    }

    /// Zooming in past the preview's detail fetches the original, once.
    private func loadFullResolution() {
        guard fullResolution == nil, isCurrent, let shown, !shown.isRAW else { return }
        fullResolution = Task {
            loading = true
            if let full = await model.original(for: shown), !Task.isCancelled {
                image = full
                isFullResolution = true
            }
            loading = false
            if !isFullResolution { fullResolution = nil }  // try again on the next zoom
        }
    }
}

/// Pinch to zoom, pan while zoomed and double-tap to zoom in or out, like Photos.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// Called once the zoom goes past what a 1620 px preview can show sharply.
    var onZoomIn: () -> Void

    func makeUIView(context: Context) -> ZoomView { ZoomView() }

    func updateUIView(_ view: ZoomView, context: Context) {
        view.onZoomIn = onZoomIn
        view.show(image)
    }
}

private final class ZoomView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    var onZoomIn: (() -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A sharper copy of the same photo keeps the current zoom.
    func show(_ image: UIImage) {
        guard imageView.image !== image else { return }
        let reshaped = imageView.image.map { abs($0.size.width / $0.size.height - image.size.width / image.size.height) > 0.01 } ?? true
        imageView.image = image
        if reshaped {
            zoomScale = 1
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale == 1, let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        contentSize = imageView.frame.size
        center()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        if zoomScale > 1.3 { onZoomIn?() }
    }

    /// Keeps the photo centred when it is smaller than the screen on either axis.
    private func center() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
