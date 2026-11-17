import CocoNotchCore
import Testing

@Test func detectsMediaKindByExtension() {
    #expect(getMediaKind(fileExtension: "JPG") == .image)
    #expect(getMediaKind(fileExtension: "webp") == .image)
    #expect(getMediaKind(fileExtension: "mov") == .video)
    #expect(getMediaKind(fileExtension: "PDF") == .pdf)
    #expect(getMediaKind(fileExtension: "docx") == nil)
}

@Test func offersOnlyWritableImageFormatsPlusPDF() {
    let outputs = getConvertOutputs(
        kinds: [.image], writableImageTypes: ["public.jpeg", "public.png", "org.webmproject.webp"])
    #expect(outputs == [.jpeg, .png, .pdf])
}

@Test func offersImageFormatsForPDFsAndMixesWithImages() {
    #expect(getConvertOutputs(kinds: [.pdf], writableImageTypes: ["public.png"]) == [.png, .pdf])
    #expect(getConvertOutputs(kinds: [.pdf, .image], writableImageTypes: ["public.png"]) == [.png, .pdf])
}

@Test func offersVideoOutputsAndNothingForMixedFiles() {
    #expect(getConvertOutputs(kinds: [.video], writableImageTypes: []) == [.mp4, .mov, .m4a, .animatedGIF])
    #expect(getConvertOutputs(kinds: [.image, .video], writableImageTypes: ["public.png"]).isEmpty)
    #expect(getConvertOutputs(kinds: [.pdf, .video], writableImageTypes: ["public.png"]).isEmpty)
    #expect(getConvertOutputs(kinds: [], writableImageTypes: ["public.png"]).isEmpty)
}

@Test func namesOutputNextToTheOriginal() {
    let path = makeOutputPath(inputPath: "/a/photo.heic", fileExtension: "jpg", folder: nil) { _ in false }
    #expect(path == "/a/photo.jpg")
}

@Test func numbersTakenNamesLikeFinder() {
    let taken: Set = ["/a/photo.jpg", "/a/photo 2.jpg"]
    let path = makeOutputPath(inputPath: "/a/photo.jpg", fileExtension: "jpg", folder: nil) { taken.contains($0) }
    #expect(path == "/a/photo 3.jpg")
}

@Test func writesIntoAChosenFolder() {
    let path = makeOutputPath(inputPath: "/a/my.clip.mov", fileExtension: "mp4", folder: "/out/") { _ in false }
    #expect(path == "/out/my.clip.mp4")
}

@Test func spacesGIFFramesAndCapsTheLength() {
    #expect(getGIFFrameTimes(duration: 1, framesPerSecond: 4, maxDuration: 10) == [0, 0.25, 0.5, 0.75])
    #expect(getGIFFrameTimes(duration: 60, framesPerSecond: 10, maxDuration: 5).count == 50)
    #expect(getGIFFrameTimes(duration: 0.05, framesPerSecond: 10, maxDuration: 5) == [0])
    #expect(getGIFFrameTimes(duration: 0, framesPerSecond: 10, maxDuration: 5).isEmpty)
}

@Test func namesPDFPagesByNumber() {
    let path = makeOutputPath(inputPath: "/a/doc.pdf", fileExtension: "png", folder: nil, pageNumber: 3) { _ in false }
    #expect(path == "/a/doc page 3.png")
}

@Test func picksExportPresets() {
    #expect(getVideoPresetName(codec: .keep, resolution: .original) == "AVAssetExportPresetPassthrough")
    #expect(getVideoPresetName(codec: .h264, resolution: .p720) == "AVAssetExportPreset1280x720")
    #expect(getVideoPresetName(codec: .hevc, resolution: .original) == "AVAssetExportPresetHEVCHighestQuality")
    #expect(getVideoResolutions(codec: .hevc) == [.original, .p2160, .p1080])
    #expect(getVideoPresetName(codec: .hevc, resolution: .p720) == "AVAssetExportPresetHEVCHighestQuality")
    #expect(getVideoPresetName(codec: .keep, resolution: .p1080) == "AVAssetExportPresetPassthrough")
}

@Test func addsOnlySupportedFilesAndStartsOverAfterABatch() {
    let added = addConvertFiles(
        ["/a/b.png", "/a/notes.txt", "/a/c.MOV", "/a/b.png"], to: ["/a/x.pdf"], isFinished: false)
    #expect(added == ["/a/x.pdf", "/a/b.png", "/a/c.MOV"])
    #expect(addConvertFiles(["/a/b.png"], to: ["/a/x.pdf"], isFinished: true) == ["/a/b.png"])
    #expect(addConvertFiles(["/a.d/pdf"], to: [], isFinished: false).isEmpty)
}

@Test func summarizesTheResult() {
    #expect(formatConvertResult(converted: 1, failed: 0) == "Converted 1 file")
    #expect(formatConvertResult(converted: 3, failed: 1) == "Converted 3 files; 1 file couldn't be converted")
}

@Test func combinesBatchProgress() {
    #expect(getBatchProgress(completed: 1, current: 0.5, total: 3) == 0.5)
    #expect(getBatchProgress(completed: 3, current: 2, total: 3) == 1)
    #expect(getBatchProgress(completed: 0, current: 0, total: 0) == 0)
}
