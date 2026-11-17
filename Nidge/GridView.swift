import NidgeKit
import SwiftUI

struct GridView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = Appearance.system
    /// Cell frames in the grid's coordinates, for drag-to-select. Not view state: writing it must not redraw.
    @State private var frames = FrameStore()
    @State private var drag: (anchor: Int, select: Bool, base: Set<String>)?
    @State private var selecting = false
    @State private var viewing: String?
    @Namespace private var zoom

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2, pinnedViews: .sectionHeaders) {
                ForEach(groupByDay(model.visibleItems), id: \.day) { group in
                    Section {
                        ForEach(group.items) { item in cell(item) }
                    } header: {
                        dayHeader(group.day, group.items)
                    }
                }
            }
            .coordinateSpace(.named("grid"))
            .gesture(HorizontalPan(changed: dragChanged) { drag = nil })
            if model.hasMore, !model.visibleItems.isEmpty {
                ProgressView().padding().onAppear { model.noteEndVisible() }
            }
        }
        .navigationTitle("Camera")
        .navigationSubtitle(status)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $viewing) { key in
            // The zoom transition also gives Photos' swipe down to close.
            PhotoViewer(current: key).navigationTransition(.zoom(sourceID: key, in: zoom))
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { optionsMenu }
            if model.isLoadingLibrary || !model.isConnected {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Cancel" : "Select") {
                    selecting.toggle()
                    if !selecting { model.selection = [] }
                }
                .disabled(model.visibleItems.isEmpty)
            }
        }
        .overlay { if model.visibleItems.isEmpty { emptyState } }
        .safeAreaInset(edge: .bottom, spacing: 0) { importBar }
        // Selection changes are instant; animating them was distracting.
        .transaction { $0.animation = nil }
        .onChange(of: model.format) { selecting = false }
    }

    // MARK: Pieces

    private func cell(_ item: PhotoItem) -> some View {
        PhotoCell(item: item, selecting: selecting)
            .matchedTransitionSource(id: item.key, in: zoom)
            .onAppear { model.noteVisible(item) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("grid")) } action: { rect in
                frames.rects[item.key] = rect
            }
            .onTapGesture { tapped(item) }
            .onLongPressGesture { longPressed(item) }
    }

    private func tapped(_ item: PhotoItem) {
        if selecting { toggle(item) } else { viewing = item.key }
    }

    private func longPressed(_ item: PhotoItem) {
        if !selecting { selecting = true }
        toggle(item)
    }

    private var status: String {
        guard model.isConnected else { return "Looking for the camera…" }
        let count = model.format == .both ? "\(model.handles.count) files" : "\(model.handles.count) photos"
        if selecting { return model.selection.isEmpty ? "Select photos" : "\(model.selection.count) selected" }
        return "Connected · \(count)"
    }

    private var optionsMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Format", selection: $model.format) {
                ForEach(FormatChoice.allCases, id: \.self) { Text($0.rawValue) }
            }
            Picker("JPEG / HEIF size", selection: $model.maxLongSide) {
                Text("Large (original)").tag(0)
                ForEach(ImageResizer.cameraSizes, id: \.longSide) { Text($0.name).tag($0.longSide) }
            }
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue) }
            }
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.isConnected {
            if !model.isLoadingLibrary, model.handles.isEmpty {
                ContentUnavailableView("No photos", systemImage: "photo.on.rectangle",
                                       description: Text(model.format == .raw ? "The card has no RAW photos." : "The card has no JPEG or HEIF photos."))
            }
        } else {
            ContentUnavailableView("Camera not found", systemImage: "camera",
                                   description: Text("Start Wi-Fi on the camera (Network menu, Connect to smart device, Wi-Fi connection), then join its network in Settings, Wi-Fi."))
        }
    }

    private func dayHeader(_ day: String, _ items: [PhotoItem]) -> some View {
        let allSelected = items.allSatisfy { model.selection.contains($0.key) || !selectable($0) }
        return HStack {
            Text(Self.title(for: day)).font(.subheadline.bold())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect()
            Spacer()
            if selecting {
                Button {
                    let keys = items.filter(selectable).map(\.key)
                    if allSelected { model.selection.subtract(keys) } else { model.selection.formUnion(keys) }
                } label: {
                    // Sized for the longer label so the button does not change width.
                    Text("Select day").hidden().overlay { Text(allSelected ? "Deselect" : "Select day") }
                }
                .font(.subheadline)
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder private var importBar: some View {
        if model.isImporting || !model.selection.isEmpty || !model.failures.isEmpty {
            importBarContent
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private var importBarContent: some View {
        VStack(spacing: 8) {
            if !model.failures.isEmpty {
                VStack(alignment: .leading) {
                    ForEach(model.failures.sorted(by: { $0.key < $1.key }), id: \.key) { name, reason in
                        Text("\(name): \(reason)")
                    }
                }
                .font(.footnote).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isImporting {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Importing \(min(model.batchDone + 1, model.batchTotal)) of \(model.batchTotal)")
                            .font(.subheadline.bold())
                        Text(model.isConnected ? (model.currentFile ?? "Waiting…") : "Connection lost. Resumes when the camera is back.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ProgressView(value: (Double(model.batchDone) + model.currentFraction) / Double(max(model.batchTotal, 1)))
                    }
                    Button("Cancel", role: .cancel) { model.cancelImport() }
                        .buttonStyle(.glass)
                }
            }
            if !model.selection.isEmpty {
                Button {
                    model.importSelection()
                    selecting = false
                } label: {
                    Text("Import ^[\(model.selection.count) photo](inflect: true)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: Selection

    /// Imported photos can be picked again, for another size or format; queued ones cannot.
    private func selectable(_ item: PhotoItem) -> Bool {
        !model.isQueued(item)
    }

    private func toggle(_ item: PhotoItem) {
        guard selectable(item) else { return }
        if model.selection.remove(item.key) == nil { model.selection.insert(item.key) }
    }

    /// In selection mode, sweeping sideways selects (or deselects, if it started on a selected
    /// photo) everything between the first photo touched and the one under the finger.
    private func dragChanged(_ location: CGPoint) {
        guard selecting else { return }
        let items = model.visibleItems
        guard let key = frames.rects.first(where: { $0.value.contains(location) })?.key,
              let index = items.firstIndex(where: { $0.key == key }) else { return }
        if drag == nil { drag = (index, !model.selection.contains(key), model.selection) }
        guard let drag else { return }
        let swept = items[min(drag.anchor, index)...max(drag.anchor, index)].filter(selectable).map(\.key)
        model.selection = drag.select ? drag.base.union(swept) : drag.base.subtracting(swept)
    }

    private static func title(for day: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyyMMdd"
        return parser.date(from: day)?.formatted(date: .complete, time: .omitted) ?? day
    }
}

enum Appearance: String, CaseIterable {
    case system = "Match system"
    case light = "Light"
    case dark = "Dark"

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private final class FrameStore {
    var rects: [String: CGRect] = [:]
}

private struct PhotoCell: View {
    @Environment(AppModel.self) private var model
    let item: PhotoItem
    let selecting: Bool
    @State private var image: UIImage?

    var body: some View {
        let selected = model.selection.contains(item.key)
        let imported = model.isImported(item)
        let queued = model.isQueued(item)
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    badge("checkmark.circle.fill", .white, Color.accentColor)
                } else if queued {
                    badge("arrow.down.circle.fill", .white, .orange)
                } else if selecting {
                    badge("circle", .white, .clear).shadow(radius: 1)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // Kept while selected, so re-importing an imported photo stays visible.
                if imported { badge("checkmark.circle.fill", .white, .green) }
            }
            .overlay(alignment: .topLeading) {
                if item.isRAW {
                    Text("RAW").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: .capsule).foregroundStyle(.white).padding(4)
                }
            }
            .overlay { if selected { Rectangle().strokeBorder(Color.accentColor, lineWidth: 3) } }
            .contentShape(Rectangle())
            // Reload when the camera comes back, for thumbnails that are not cached yet.
            .task(id: model.isConnected) {
                if image == nil { image = await model.thumbnail(for: item) }
            }
            .accessibilityElement()
            .accessibilityLabel(item.filename)
            .accessibilityValue([imported ? "Imported" : nil, queued ? "Waiting to import" : nil, selected ? "Selected" : nil]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(selecting ? "Selects or deselects the photo" : "Opens the photo")
    }

    private func badge(_ name: String, _ foreground: Color, _ background: Color) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.palette)
            .foregroundStyle(foreground, background)
            .font(.title3)
            .padding(4)
    }
}

/// A pan that only begins when it starts sideways, so vertical drags still scroll the grid.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    var changed: (CGPoint) -> Void
    var ended: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Delegate { Delegate() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: changed(context.converter.localLocation)
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }

    final class Delegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
