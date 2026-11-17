import Foundation

public enum MediaKind: Sendable {
    case image
    case video
    case pdf
}

private let imageExtensions: Set = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "gif", "bmp", "webp"]
private let videoExtensions: Set = ["mov", "mp4", "m4v"]

/// What a file is by its extension, or nil when Convert can't read it.
public func getMediaKind(fileExtension: String) -> MediaKind? {
    let lowered = fileExtension.lowercased()
    if imageExtensions.contains(lowered) { return .image }
    if videoExtensions.contains(lowered) { return .video }
    return lowered == "pdf" ? .pdf : nil
}

public enum ConvertOutput: String, CaseIterable, Sendable {
    case heic, jpeg, png, tiff, gif, bmp
    /// Every image and PDF page combined into one PDF.
    case pdf
    case mp4, mov
    /// The video's sound only.
    case m4a
    /// A video turned into a looping GIF.
    case animatedGIF

    public var fileExtension: String {
        switch self {
        case .heic: "heic"
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        case .gif, .animatedGIF: "gif"
        case .bmp: "bmp"
        case .pdf: "pdf"
        case .mp4: "mp4"
        case .mov: "mov"
        case .m4a: "m4a"
        }
    }

    public var title: String {
        switch self {
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .pdf: "PDF"
        case .mp4: "MP4"
        case .mov: "MOV"
        case .m4a: "Audio (M4A)"
        case .animatedGIF: "GIF"
        }
    }

    /// The Uniform Type Identifier ImageIO writes for an image output; nil for the others.
    public var imageTypeIdentifier: String? {
        switch self {
        case .heic: "public.heic"
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .bmp: "com.microsoft.bmp"
        default: nil
        }
    }

    public var isLossy: Bool { self == .heic || self == .jpeg }
}

/// The outputs for a set of dropped files: images and PDFs get the image formats this Mac can write (a PDF gives one
/// image per page) plus a combined PDF; videos get video, audio and GIF. A mix with videos, or nothing, has no outputs.
public func getConvertOutputs(kinds: Set<MediaKind>, writableImageTypes: Set<String>) -> [ConvertOutput] {
    if kinds == [.video] { return [.mp4, .mov, .m4a, .animatedGIF] }
    guard !kinds.isEmpty, kinds.isSubset(of: [.image, .pdf]) else { return [] }
    return ConvertOutput.allCases.filter { $0.imageTypeIdentifier.map(writableImageTypes.contains) ?? false } + [.pdf]
}

/// Where a converted file goes: `folder`, or next to the original, numbered like Finder ("photo 2.jpg") when the name
/// is taken. Paths are plain strings so this stays free of Foundation's file APIs.
public func makeOutputPath(
    inputPath: String, fileExtension: String, folder: String?, pageNumber: Int? = nil, exists: (String) -> Bool
) -> String {
    let slash = inputPath.lastIndex(of: "/")
    let name = slash.map { String(inputPath[inputPath.index(after: $0)...]) } ?? inputPath
    let directory = folder ?? slash.map { String(inputPath[..<$0]) } ?? "."
    let stem =
        (name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name) + (pageNumber.map { " page \($0)" } ?? "")
    let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
    var candidate = "\(base)/\(stem).\(fileExtension)"
    var number = 2
    while exists(candidate) {
        candidate = "\(base)/\(stem) \(number).\(fileExtension)"
        number += 1
    }
    return candidate
}

/// The moments to grab a GIF's frames at: evenly spaced at `framesPerSecond`, stopping at `maxDuration`.
public func getGIFFrameTimes(duration: Double, framesPerSecond: Int, maxDuration: Double) -> [Double] {
    guard duration > 0, framesPerSecond > 0 else { return [] }
    let length = min(duration, maxDuration)
    let count = max(Int((length * Double(framesPerSecond)).rounded(.down)), 1)
    return (0..<count).map { Double($0) / Double(framesPerSecond) }
}

public enum VideoCodec: String, CaseIterable, Sendable {
    /// Copies the streams into the new container without re-encoding, so it's fast and lossless.
    case keep
    case h264
    case hevc

    public var title: String {
        switch self {
        case .keep: "Keep (fastest)"
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

/// The height a video is shrunk to fit, or 0 for the original size.
public enum VideoResolution: Int, CaseIterable, Sendable {
    case original = 0
    case p2160 = 2160
    case p1080 = 1080
    case p720 = 720
    case p480 = 480

    public var title: String { self == .original ? "Original" : "\(rawValue)p" }
}

/// The sizes AVFoundation has export presets for with this codec.
public func getVideoResolutions(codec: VideoCodec) -> [VideoResolution] {
    switch codec {
    case .keep: [.original]
    case .h264: VideoResolution.allCases
    case .hevc: [.original, .p2160, .p1080]
    }
}

/// The AVAssetExportSession preset name; the AVFoundation constants are these same strings. A size the codec has no
/// preset for falls back to the original size.
public func getVideoPresetName(codec: VideoCodec, resolution: VideoResolution) -> String {
    let resolution = getVideoResolutions(codec: codec).contains(resolution) ? resolution : .original
    let size: String? =
        switch resolution {
        case .original: nil
        case .p2160: "3840x2160"
        case .p1080: "1920x1080"
        case .p720: "1280x720"
        case .p480: "640x480"
        }
    switch codec {
    case .keep: return "AVAssetExportPresetPassthrough"
    case .h264: return "AVAssetExportPreset" + (size ?? "HighestQuality")
    case .hevc: return "AVAssetExportPresetHEVC" + (size ?? "HighestQuality")
    }
}

/// The files a drop leaves to convert: supported ones added after the current ones without repeats, or, once the last
/// batch is done, in place of it.
public func addConvertFiles(_ newPaths: [String], to paths: [String], isFinished: Bool) -> [String] {
    var result = isFinished ? [] : paths
    for path in newPaths
    where !result.contains(path) && getMediaKind(fileExtension: (path as NSString).pathExtension) != nil {
        result.append(path)
    }
    return result
}

/// "Converted 3 files", adding how many couldn't be.
public func formatConvertResult(converted: Int, failed: Int) -> String {
    let files = { (count: Int) in count == 1 ? "1 file" : "\(count) files" }
    let done = "Converted \(files(converted))"
    return failed == 0 ? done : "\(done); \(files(failed)) couldn't be converted"
}

/// Overall progress of a batch, from the files already done and how far the current one is.
public func getBatchProgress(completed: Int, current: Double, total: Int) -> Double {
    guard total > 0 else { return 0 }
    return min(max((Double(completed) + min(max(current, 0), 1)) / Double(total), 0), 1)
}
