import AVFoundation
import CocoNotchCore
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension NotchWidget {
    static let convert = NotchWidget(
        id: "convert",
        title: "Convert",
        systemImage: "arrow.triangle.2.circlepath",
        makeView: { AnyView(ConvertView()) },
        makeSettings: { AnyView(ConvertSettings()) }
    )
}

private let imageQualityKey = "convert.imageQuality"
private let maxImageSideKey = "convert.maxImageSide"
private let videoCodecKey = "convert.videoCodec"
private let videoResolutionKey = "convert.videoResolution"
private let gifFramesPerSecondKey = "convert.gifFramesPerSecond"
private let gifMaxDurationKey = "convert.gifMaxDuration"
private let gifMaxSideKey = "convert.gifMaxSide"
private let outputFolderKey = "convert.outputFolder"
private let revealsOutputKey = "convert.revealsOutput"

private func readSetting<Value>(_ key: String, default defaultValue: Value) -> Value {
    UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue
}

/// The settings a batch runs with, read once when it starts.
nonisolated private struct ConvertOptions: Sendable {
    var imageQuality: Double
    /// The longest side for images and PDF pages; nil keeps the original size.
    var maxImageSide: Int?
    var videoPresetName: String
    var gifFramesPerSecond: Int
    var gifMaxDuration: Double
    var gifMaxSide: Int
    /// Where outputs go; nil puts each next to its original.
    var folder: String?
}

@MainActor private func readConvertOptions() -> ConvertOptions {
    let maxImageSide = readSetting(maxImageSideKey, default: 0)
    let folder = readSetting(outputFolderKey, default: "")
    return ConvertOptions(
        imageQuality: readSetting(imageQualityKey, default: 0.85),
        maxImageSide: maxImageSide > 0 ? maxImageSide : nil,
        videoPresetName: getVideoPresetName(
            codec: VideoCodec(rawValue: readSetting(videoCodecKey, default: "")) ?? .keep,
            resolution: VideoResolution(rawValue: readSetting(videoResolutionKey, default: 0)) ?? .original),
        gifFramesPerSecond: readSetting(gifFramesPerSecondKey, default: 10),
        gifMaxDuration: readSetting(gifMaxDurationKey, default: 10.0),
        gifMaxSide: readSetting(gifMaxSideKey, default: 480),
        folder: folder.isEmpty ? nil : folder
    )
}

/// Holds the batch for the whole app, so a conversion keeps going and its result stays when the notch closes.
@Observable
private final class ConvertStore {
    static let shared = ConvertStore()

    private(set) var paths: [String] = []
    private(set) var completed = 0
    /// How far the file being converted is, from 0 to 1.
    private(set) var currentProgress = 0.0
    private(set) var isRunning = false
    private(set) var result: String?
    private(set) var outputURLs: [URL] = []
    @ObservationIgnored private let writableImageTypes = Set(
        CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    var progress: Double {
        getBatchProgress(completed: completed, current: currentProgress, total: paths.count)
    }

    var outputs: [ConvertOutput] {
        getConvertOutputs(
            kinds: Set(paths.compactMap { getMediaKind(fileExtension: ($0 as NSString).pathExtension) }),
            writableImageTypes: writableImageTypes)
    }

    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        paths = addConvertFiles(
            urls.map { $0.path(percentEncoded: false) }, to: paths, isFinished: result != nil)
        result = nil
        outputURLs = []
    }

    func clear() {
        guard !isRunning else { return }
        paths = []
        result = nil
        outputURLs = []
    }

    func convert(to output: ConvertOutput) {
        let inputs = paths.map { URL(filePath: $0) }
        let options = readConvertOptions()
        isRunning = true
        completed = 0
        currentProgress = 0
        Task {
            var made: [URL] = []
            var failed = 0
            if output == .pdf, let first = inputs.first {
                let url = makeOutputURL(for: first, fileExtension: output.fileExtension, folder: options.folder)
                do {
                    try await Task.detached { try combinePDF(inputs, into: url) }.value
                    made = [url]
                } catch {
                    print("CocoNotch couldn't combine the files into a PDF: \(error)")
                    failed = inputs.count
                }
                completed = inputs.count
            } else {
                for (index, input) in inputs.enumerated() {
                    // A late update from the file before mustn't move the bar for this one.
                    let onProgress: @Sendable (Double) -> Void = { fraction in
                        Task { @MainActor in if self.completed == index { self.currentProgress = fraction } }
                    }
                    do {
                        made += try await Task.detached {
                            try await convertFile(input, to: output, options: options, onProgress: onProgress)
                        }
                        .value
                    } catch {
                        print("CocoNotch couldn't convert \(input.lastPathComponent): \(error)")
                        failed += 1
                    }
                    completed += 1
                    currentProgress = 0
                }
            }
            outputURLs = made
            result = formatConvertResult(converted: inputs.count - failed, failed: failed)
            isRunning = false
            if !made.isEmpty, readSetting(revealsOutputKey, default: false) { revealInFinder() }
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
    }
}

nonisolated private func makeOutputURL(
    for input: URL, fileExtension: String, folder: String?, pageNumber: Int? = nil
) -> URL {
    URL(
        filePath: makeOutputPath(
            inputPath: input.path(percentEncoded: false), fileExtension: fileExtension, folder: folder,
            pageNumber: pageNumber
        ) { FileManager.default.fileExists(atPath: $0) })
}

/// Converts one file and returns what it wrote: one file, or one image per page of a PDF.
nonisolated private func convertFile(
    _ input: URL, to output: ConvertOutput, options: ConvertOptions, onProgress: @escaping @Sendable (Double) -> Void
) async throws -> [URL] {
    let url = makeOutputURL(for: input, fileExtension: output.fileExtension, folder: options.folder)
    switch output {
    case .mp4, .mov, .m4a:
        try await exportVideo(
            input, to: url, as: output, presetName: options.videoPresetName, onProgress: onProgress)
        return [url]
    case .animatedGIF:
        try await makeGIF(from: input, to: url, options: options, onProgress: onProgress)
        return [url]
    default:
        guard let type = output.imageTypeIdentifier else { throw CocoaError(.featureUnsupported) }
        if getMediaKind(fileExtension: input.pathExtension) == .pdf {
            return try renderPDFPages(input, as: output, type: type, options: options)
        }
        try convertImage(input, to: url, type: type, options: options)
        return [url]
    }
}

nonisolated private func convertImage(_ input: URL, to url: URL, type: String, options: ConvertOptions) throws {
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        // The thumbnail call scales and applies the EXIF orientation, so a portrait photo stays upright.
        let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: options.maxImageSide ?? max(width, height),
            ] as CFDictionary)
    else { throw CocoaError(.fileReadCorruptFile) }
    try writeImage(image, to: url, type: type, quality: options.imageQuality)
}

nonisolated private func writeImage(_ image: CGImage, to url: URL, type: String, quality: Double) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

nonisolated private func renderPDFPages(
    _ input: URL, as output: ConvertOutput, type: String, options: ConvertOptions
) throws -> [URL] {
    guard let document = PDFDocument(url: input), document.pageCount > 0 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return try (0..<document.pageCount).compactMap { index in
        guard let page = document.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        // Twice the page's point size, like a Retina screen, unless a smaller size is set.
        let side = CGFloat(options.maxImageSide ?? Int(max(bounds.width, bounds.height) * 2))
        guard
            let image = page.thumbnail(of: NSSize(width: side, height: side), for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        let url = makeOutputURL(
            for: input, fileExtension: output.fileExtension, folder: options.folder,
            pageNumber: document.pageCount == 1 ? nil : index + 1)
        try writeImage(image, to: url, type: type, quality: options.imageQuality)
        return url
    }
}

/// Puts every image and every PDF page, in order, into one PDF.
nonisolated private func combinePDF(_ inputs: [URL], into url: URL) throws {
    let combined = PDFDocument()
    // Kept until the write, since a moved page still reads from the document it came from.
    var sources: [PDFDocument] = []
    for input in inputs {
        var pages: [PDFPage] = []
        if getMediaKind(fileExtension: input.pathExtension) == .pdf, let source = PDFDocument(url: input) {
            sources.append(source)
            pages = (0..<source.pageCount).compactMap(source.page(at:))
        } else if let image = NSImage(contentsOf: input), let page = PDFPage(image: image) {
            pages = [page]
        }
        guard !pages.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        for page in pages { combined.insert(page, at: combined.pageCount) }
    }
    guard combined.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
}

// On the main actor so the progress watcher and the export share one session; the encoding runs off it.
@MainActor private func exportVideo(
    _ input: URL, to url: URL, as output: ConvertOutput, presetName: String,
    onProgress: @escaping @Sendable (Double) -> Void
) async throws {
    guard
        let session = AVAssetExportSession(
            asset: AVURLAsset(url: input), presetName: output == .m4a ? AVAssetExportPresetAppleM4A : presetName)
    else { throw CocoaError(.featureUnsupported) }
    let watcher = Task {
        for await state in session.states(updateInterval: 0.25) {
            if case .exporting(let progress) = state { onProgress(progress.fractionCompleted) }
        }
    }
    defer { watcher.cancel() }
    let fileType: AVFileType =
        switch output {
        case .mp4: .mp4
        case .m4a: .m4a
        default: .mov
        }
    try await session.export(to: url, as: fileType)
}

nonisolated private func makeGIF(
    from input: URL, to url: URL, options: ConvertOptions, onProgress: @escaping @Sendable (Double) -> Void
) async throws {
    let asset = AVURLAsset(url: input)
    let times = getGIFFrameTimes(
        duration: try await asset.load(.duration).seconds, framesPerSecond: options.gifFramesPerSecond,
        maxDuration: options.gifMaxDuration)
    guard !times.isEmpty,
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, times.count, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    // Fits the box keeping the video's shape.
    generator.maximumSize = CGSize(width: options.gifMaxSide, height: options.gifMaxSide)
    CGImageDestinationSetProperties(
        destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProperties =
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / Double(options.gifFramesPerSecond)]]
        as CFDictionary
    for (index, time) in times.enumerated() {
        let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        CGImageDestinationAddImage(destination, image, frameProperties)
        onProgress(Double(index + 1) / Double(times.count))
    }
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

private struct ConvertView: View {
    @State private var isTargeted = false
    private let store = ConvertStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.paths.isEmpty {
                Text("Drop images, videos or PDFs here")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
            } else {
                HStack(spacing: 8) {
                    Text(
                        store.paths.count == 1
                            ? (store.paths[0] as NSString).lastPathComponent : "\(store.paths.count) files"
                    )
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.paths.joined(separator: "\n"))
                    Spacer()
                    Button("Clear", systemImage: "xmark.circle") { store.clear() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(store.isRunning)
                        .help("Clear")
                }
                let outputs = store.outputs
                if outputs.isEmpty {
                    Text("Videos can't be converted together with images or PDFs.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text("Convert to")
                            .foregroundStyle(.secondary)
                        ForEach(outputs, id: \.self) { output in
                            Button(output.title) { store.convert(to: output) }
                                .help(output == .pdf ? "Combine everything into one PDF" : "")
                        }
                    }
                    .disabled(store.isRunning)
                }
                if store.isRunning {
                    ProgressView(value: store.progress)
                } else if let result = store.result {
                    HStack(spacing: 8) {
                        Text(result)
                            .foregroundStyle(.secondary)
                        if !store.outputURLs.isEmpty {
                            Button("Show in Finder") { store.revealInFinder() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(isTargeted ? 0.1 : 0.04))
                .strokeBorder(
                    Color.primary.opacity(isTargeted ? 0.4 : 0.12),
                    style: StrokeStyle(lineWidth: 1, dash: store.paths.isEmpty ? [5] : []))
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls)
            return true
        } isTargeted: {
            isTargeted = $0
        }
    }
}

private struct ConvertSettings: View {
    @AppStorage(imageQualityKey) private var imageQuality = 0.85
    @AppStorage(maxImageSideKey) private var maxImageSide = 0
    @AppStorage(videoCodecKey) private var videoCodec = VideoCodec.keep
    @AppStorage(videoResolutionKey) private var videoResolution = VideoResolution.original
    @AppStorage(gifFramesPerSecondKey) private var gifFramesPerSecond = 10
    @AppStorage(gifMaxDurationKey) private var gifMaxDuration = 10.0
    @AppStorage(gifMaxSideKey) private var gifMaxSide = 480
    @AppStorage(outputFolderKey) private var outputFolder = ""
    @AppStorage(revealsOutputKey) private var revealsOutput = false

    var body: some View {
        Form {
            Section {
                Slider(value: $imageQuality, in: 0.1...1) {
                    Text("Quality")
                } minimumValueLabel: {
                    Text("Smaller")
                } maximumValueLabel: {
                    Text("Better")
                }
                Picker("Longest side", selection: $maxImageSide) {
                    Text("Original").tag(0)
                    ForEach([4096, 2048, 1024, 512], id: \.self) { Text("\($0) px").tag($0) }
                }
            } header: {
                Text("Images and PDF pages")
            } footer: {
                Text("Quality applies to JPEG and HEIC. Images are never made bigger than the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Codec", selection: $videoCodec) {
                    ForEach(VideoCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Resolution", selection: $videoResolution) {
                    ForEach(getVideoResolutions(codec: videoCodec), id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(videoCodec == .keep)
            } header: {
                Text("Video")
            } footer: {
                Text("Keep copies the video into the new format without re-encoding, so it's quick and lossless.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("GIF from video") {
                Stepper("\(gifFramesPerSecond) frames per second", value: $gifFramesPerSecond, in: 1...30)
                Stepper("First \(Int(gifMaxDuration)) seconds", value: $gifMaxDuration, in: 1...60)
                Picker("Longest side", selection: $gifMaxSide) {
                    ForEach([320, 480, 640, 800, 1080], id: \.self) { Text("\($0) px").tag($0) }
                }
            }
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(outputFolder.isEmpty ? "Next to the original" : outputFolder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                        if !outputFolder.isEmpty {
                            Button("Reset") { outputFolder = "" }
                        }
                    }
                }
                Toggle("Show converted files in Finder", isOn: $revealsOutput)
            } header: {
                Text("Output")
            } footer: {
                Text("Originals are never replaced; a taken name gets a number, like Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: videoCodec) { _, codec in
            if !getVideoResolutions(codec: codec).contains(videoResolution) { videoResolution = .original }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url.path(percentEncoded: false) }
    }
}
