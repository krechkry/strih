// Vendored from soniqo/speech-swift (Apache-2.0), Sources/SpeechEnhancement: the Core ML path of
// DeepFilterNet3 (Apache-2.0 / MIT). MLX backend and model downloading removed; the model ships in the app.

import Foundation

/// Configuration for DeepFilterNet3 speech enhancement model.
struct DeepFilterNet3Config {
    /// FFT window size
    let fftSize: Int
    /// Hop size (frame shift) in samples
    let hopSize: Int
    /// Number of ERB frequency bands
    let erbBands: Int
    /// Number of frequency bins for deep filtering (lowest bins)
    let dfBins: Int
    /// Deep filter order (number of taps)
    let dfOrder: Int
    /// Deep filter lookahead in frames
    let dfLookahead: Int
    /// Number of convolution channels
    let convCh: Int
    /// Embedding/GRU hidden dimension
    let embHidden: Int
    /// Number of GRU layers in encoder
    let encGruLayers: Int
    /// Number of GRU layers in ERB decoder
    let erbDecGruLayers: Int
    /// DF decoder hidden dimension
    let dfHidden: Int
    /// Number of GRU layers in DF decoder
    let dfGruLayers: Int
    /// Groups for encoder linear layer
    let encLinGroups: Int
    /// Groups for linear layers in SqueezedGRU
    let linGroups: Int
    /// Sample rate
    let sampleRate: Int
    /// Convolution lookahead in frames
    let convLookahead: Int
    /// LSNR max value
    let lsnrMax: Float
    /// LSNR min value
    let lsnrMin: Float
    /// Exponential normalization time constant
    let normTau: Float

    /// Number of FFT frequency bins (fftSize / 2 + 1)
    var freqBins: Int { fftSize / 2 + 1 }

    /// Normalization alpha (exponential decay), rounded like upstream libdf.
    var normAlpha: Float {
        let unrounded = exp(-Float(hopSize) / Float(sampleRate) / normTau)
        var scale: Float = 1_000

        // DeepFilterNet's `get_norm_alpha` starts at three decimal places and
        // increases precision only if rounding would produce 1.0. The default
        // model was trained and exported with 0.99, not exp(-0.01).
        while scale.isFinite {
            let rounded = (unrounded * scale).rounded() / scale
            if rounded < 1 { return rounded }
            scale *= 10
        }
        return unrounded
    }

    /// Default configuration matching the pretrained DeepFilterNet3 model.
    static let `default` = DeepFilterNet3Config(
        fftSize: 960,
        hopSize: 480,
        erbBands: 32,
        dfBins: 96,
        dfOrder: 5,
        dfLookahead: 2,
        convCh: 64,
        embHidden: 256,
        encGruLayers: 1,
        erbDecGruLayers: 2,
        dfHidden: 256,
        dfGruLayers: 2,
        encLinGroups: 32,
        linGroups: 16,
        sampleRate: 48000,
        convLookahead: 2,
        lsnrMax: 35,
        lsnrMin: -15,
        normTau: 1.0
    )
}
