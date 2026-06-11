import AVFoundation
import ImageIO
import CoreVideo
import Foundation

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: output)

guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else { fatalError("no source") }
let count = CGImageSourceGetCount(src)
print("frames: \(count)")
guard count > 0, let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("no frames") }
let width = (first.width / 2) * 2
let height = (first.height / 2) * 2

let writer = try! AVAssetWriter(outputURL: output, fileType: .mov)
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height
]
let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height
])
writer.add(writerInput)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

var time = CMTime.zero
for index in 0..<count {
    guard let cg = CGImageSourceCreateImageAtIndex(src, index, nil) else { continue }
    var duration = 0.1
    if let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] {
        let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        duration = (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
            ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.1
        if duration < 0.011 { duration = 0.1 }
    }
    while !writerInput.isReadyForMoreMediaData { usleep(2000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let pb else { continue }
    CVPixelBufferLockBaseAddress(pb, [])
    if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                           bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    adaptor.append(pb, withPresentationTime: time)
    time = CMTimeAdd(time, CMTime(seconds: duration, preferredTimescale: 600))
}
writerInput.markAsFinished()
let sema = DispatchSemaphore(value: 0)
writer.finishWriting { sema.signal() }
sema.wait()
print("wrote \(output.path), duration \(time.seconds)s")
