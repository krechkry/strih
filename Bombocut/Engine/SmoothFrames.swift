import AVFoundation
import CoreImage
import VideoToolbox

/// Apple's machine-learning frame engine (iOS 26+, real devices): invents in-between frames for smooth slow
/// motion and adds real motion blur from the movement between frames. Falls back to simple frame blending.
final class SmoothFrames: @unchecked Sendable {
    static let shared = SmoothFrames()

    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "bombocut.smoothframes")
    private var sessions: [String: AnyObject] = [:]

    /// Size the frame engine works at: the source fitted to the output (export) or to 60 % of it (editor
    /// playback, so it keeps up frame by frame). Never larger than the source. Even sizes only.
    static func workSize(source: CGSize, render: CGSize, preview: Bool) -> CGSize {
        let k = preview ? 0.6 : 1.0
        let fit = min(1, max(render.width, render.height) * k / max(source.width, source.height, 1))
        func even(_ v: CGFloat) -> CGFloat { max(64, (v * fit / 2).rounded() * 2) }
        return CGSize(width: even(source.width), height: even(source.height))
    }

    // MARK: Smooth slow motion

    /// A frame `phase` (0...1) of the way from `cur` to `next`.
    func interpolate(cur: CVPixelBuffer, next: CVPixelBuffer, phase: Double, time: CMTime, work: CGSize,
                     completion: @escaping (CIImage) -> Void) {
        #if !targetEnvironment(simulator)
        if #available(iOS 26.0, *), VTFrameRateConversionConfiguration.isSupported {
            queue.async {
                if let out = self.frc(cur: cur, next: next, phase: Float(phase), time: time, work: work) {
                    completion(out)
                } else {
                    completion(Self.blend(cur, next, phase))
                }
            }
            return
        }
        #endif
        completion(Self.blend(cur, next, phase))
    }

    // MARK: Motion blur

    /// Blur along the movement; `strength` 0...1.
    func motionBlur(cur: CVPixelBuffer, prev: CVPixelBuffer?, next: CVPixelBuffer?, strength: Double, time: CMTime,
                    work: CGSize, completion: @escaping (CIImage) -> Void) {
        #if !targetEnvironment(simulator)
        if #available(iOS 26.0, *), VTMotionBlurConfiguration.isSupported {
            queue.async {
                if let out = self.blur(cur: cur, prev: prev, next: next, strength: strength, time: time, work: work) {
                    completion(out)
                } else {
                    completion(Self.average(cur, prev, next, strength))
                }
            }
            return
        }
        #endif
        completion(Self.average(cur, prev, next, strength))
    }

    // MARK: Fallbacks (any device)

    static func blend(_ a: CVPixelBuffer, _ b: CVPixelBuffer, _ f: Double) -> CIImage {
        let ia = CIImage(cvPixelBuffer: a), ib = CIImage(cvPixelBuffer: b)
        return ia.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: ib, kCIInputTimeKey: f])
    }

    static func average(_ cur: CVPixelBuffer, _ prev: CVPixelBuffer?, _ next: CVPixelBuffer?, _ s: Double) -> CIImage {
        var out = CIImage(cvPixelBuffer: cur)
        let w = min(max(s, 0), 1) * 0.45
        if let p = prev { out = out.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: CIImage(cvPixelBuffer: p), kCIInputTimeKey: w]) }
        if let n = next { out = out.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: CIImage(cvPixelBuffer: n), kCIInputTimeKey: w * 0.8]) }
        return out
    }

    // MARK: Video Toolbox

    #if !targetEnvironment(simulator)
    @available(iOS 26.0, *)
    private final class Session {
        let processor = VTFrameProcessor()
        let inPool: CVPixelBufferPool
        let outPool: CVPixelBufferPool
        var lastTime: CMTime = .invalid

        init?(config: any VTFrameProcessorConfiguration, width: Int, height: Int) {
            func pool(_ attrs: [String: Any]) -> CVPixelBufferPool? {
                var a = attrs
                a[kCVPixelBufferWidthKey as String] = width
                a[kCVPixelBufferHeightKey as String] = height
                a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
                var p: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &p)
                return p
            }
            guard let i = pool(config.sourcePixelBufferAttributes), let o = pool(config.destinationPixelBufferAttributes),
                  (try? processor.startSession(configuration: config)) != nil else { return nil }
            inPool = i
            outPool = o
        }

        func buffer(_ p: CVPixelBufferPool) -> CVPixelBuffer? {
            var b: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, p, &b)
            return b
        }

        deinit { processor.endSession() }
    }

    @available(iOS 26.0, *)
    private func session(_ kind: String, width: Int, height: Int, make: () -> (any VTFrameProcessorConfiguration)?) -> Session? {
        let key = "\(kind)|\(width)x\(height)"
        if let s = sessions[key] as? Session { return s }
        // one size per kind at a time: drop older sessions of this kind
        sessions = sessions.filter { !$0.key.hasPrefix(kind + "|") }
        guard let cfg = make(), let s = Session(config: cfg, width: width, height: height) else { return nil }
        sessions[key] = s
        return s
    }

    /// Copies a frame into the processor's pixel format.
    @available(iOS 26.0, *)
    private func frame(_ src: CVPixelBuffer, in s: Session, time: CMTime) -> VTFrameProcessorFrame? {
        guard let b = s.buffer(s.inPool) else { return nil }
        var img = CIImage(cvPixelBuffer: src)
        let sx = CGFloat(CVPixelBufferGetWidth(b)) / img.extent.width, sy = CGFloat(CVPixelBufferGetHeight(b)) / img.extent.height
        if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
            img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        ctx.render(img, to: b)
        return VTFrameProcessorFrame(buffer: b, presentationTimeStamp: time)
    }

    /// The engine's output, scaled back to the source size so the rest of the pipeline is unchanged.
    private func back(_ out: CVPixelBuffer, to src: CVPixelBuffer) -> CIImage {
        let img = CIImage(cvPixelBuffer: out)
        let sx = CGFloat(CVPixelBufferGetWidth(src)) / img.extent.width, sy = CGFloat(CVPixelBufferGetHeight(src)) / img.extent.height
        if abs(sx - 1) < 0.001 && abs(sy - 1) < 0.001 { return img }
        return img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    /// Runs one request and waits for it (we are on our own serial queue).
    @available(iOS 26.0, *)
    private func run(_ s: Session, _ params: any VTFrameProcessorParameters) -> Bool {
        let done = DispatchSemaphore(value: 0)
        var ok = false
        s.processor.process(parameters: params) { _, error in
            ok = error == nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        return ok
    }

    @available(iOS 26.0, *)
    private func frc(cur: CVPixelBuffer, next: CVPixelBuffer, phase: Float, time: CMTime, work: CGSize) -> CIImage? {
        let w = Int(work.width), h = Int(work.height)
        guard w <= 4096, h <= 4096, let s = session("frc", width: w, height: h, make: {
            VTFrameRateConversionConfiguration(frameWidth: w, frameHeight: h, usePrecomputedFlow: false,
                                               qualityPrioritization: .normal,
                                               revision: VTFrameRateConversionConfiguration.defaultRevision)
        }) else { return nil }
        let next1 = CMTimeAdd(time, CMTime(value: 1, timescale: 600))
        guard let a = frame(cur, in: s, time: time), let b = frame(next, in: s, time: next1),
              let outBuf = s.buffer(s.outPool),
              let dst = VTFrameProcessorFrame(buffer: outBuf, presentationTimeStamp: time) else { return nil }
        let mode: VTFrameRateConversionParameters.SubmissionMode = s.lastTime == time ? .sequentialReferencesUnchanged : .random
        s.lastTime = time
        guard let p = VTFrameRateConversionParameters(sourceFrame: a, nextFrame: b, opticalFlow: nil,
                                                      interpolationPhase: [min(max(phase, 0.01), 0.99)],
                                                      submissionMode: mode, destinationFrames: [dst]),
              run(s, p) else { return nil }
        return back(outBuf, to: cur)
    }

    @available(iOS 26.0, *)
    private func blur(cur: CVPixelBuffer, prev: CVPixelBuffer?, next: CVPixelBuffer?, strength: Double, time: CMTime,
                      work: CGSize) -> CIImage? {
        let w = Int(work.width), h = Int(work.height)
        guard w <= 4096, h <= 4096, let s = session("blur", width: w, height: h, make: {
            VTMotionBlurConfiguration(frameWidth: w, frameHeight: h, usePrecomputedFlow: false,
                                      qualityPrioritization: .normal,
                                      revision: VTMotionBlurConfiguration.defaultRevision)
        }) else { return nil }
        let step = CMTime(value: 1, timescale: 600)
        guard let c = frame(cur, in: s, time: time), let outBuf = s.buffer(s.outPool),
              let dst = VTFrameProcessorFrame(buffer: outBuf, presentationTimeStamp: time) else { return nil }
        let n = next.flatMap { frame($0, in: s, time: CMTimeAdd(time, step)) }
        let p = prev.flatMap { frame($0, in: s, time: CMTimeSubtract(time, step)) }
        let mode: VTMotionBlurParameters.SubmissionMode =
            s.lastTime.isValid && CMTimeCompare(time, s.lastTime) > 0 && CMTimeGetSeconds(CMTimeSubtract(time, s.lastTime)) < 0.1
            ? .sequential : .random
        s.lastTime = time
        guard let params = VTMotionBlurParameters(sourceFrame: c, nextFrame: n, previousFrame: p,
                                                  nextOpticalFlow: nil, previousOpticalFlow: nil,
                                                  motionBlurStrength: max(1, min(100, Int(strength * 100))),
                                                  submissionMode: mode, destinationFrame: dst),
              run(s, params) else { return nil }
        return back(outBuf, to: cur)
    }
    #endif
}
