---
license: apache-2.0
tags:
- speech-enhancement
- denoising
- coreml
- apple-silicon
- deepfilternet
- int8
- palettization
base_model: Rikorose/DeepFilterNet3
library_name: coreml
pipeline_tag: audio-to-audio
---

# DeepFilterNet3 — CoreML INT8

Real-time speech enhancement for Apple Silicon. Removes background noise
from speech audio. Runs on **Neural Engine** via CoreML.

- **2.1M params**, INT8 k-means palettization, **2.2 MB**
- 48 kHz native, 10 ms frames
- Requires macOS 14+ / iOS 17+

## Quality

Measured on 30 VoiceBank-DEMAND test clips via Python `CoreMLBackend`
(replaces only the NN forward; keeps the PyTorch STFT / ERB / deep-filter
post-processing intact).

| Variant | PESQ | STOI | SI-SDR | Size |
|---------|------|------|--------|------|
| PyTorch FP32 (reference) | 2.900 | 0.947 | 18.19 | — |
| CoreML FP16 | 2.901 | 0.947 | 18.19 | 4.2 MB |
| **CoreML INT8 (this repo)** | **2.907** | **0.947** | **18.11** | **2.2 MB** |

INT8 matches FP16 within run-to-run noise (ΔPESQ +0.006, ΔSI-SDR
−0.07 dB, STOI identical) while cutting size by 48%.

## Latency (M2 Max)

| Duration | Time | RTF |
|----------|------|-----|
| 5 s | 0.65 s | 0.13 |
| 10 s | 1.2 s | 0.12 |
| 20 s | 4.8 s | 0.24 |

## Files

| File | Size | Description |
|------|------|-------------|
| `DeepFilterNet3.mlmodelc` | 2.2 MB | Pre-compiled CoreML model (runs on Neural Engine) |
| `auxiliary.npz` | 126 KB | ERB filterbank, Vorbis window, normalization states |

## Usage

Add [speech-swift](https://github.com/soniqo/speech-swift) to `Package.swift`:

```swift
.package(url: "https://github.com/soniqo/speech-swift", branch: "main")
```

Then denoise:

```swift
import SpeechEnhancement

let enhancer = try await SpeechEnhancer.fromPretrained()
let clean = try enhancer.enhance(audio: noisyAudio, sampleRate: 48000)
```

CLI:

```bash
swift run audio denoise noisy.wav --output clean.wav
```

## Source

- Base model: [Rikorose/DeepFilterNet3](https://github.com/Rikorose/DeepFilterNet) (Apache-2.0)

## License

- Model weights: Apache-2.0 / MIT dual license
- CoreML conversion: Apache-2.0

## Links

- [speech-swift](https://github.com/soniqo/speech-swift) — Apple SDK
- [soniqo.audio](https://soniqo.audio) — website
- [MLX vs CoreML on Apple Silicon — a practical guide](https://blog.ivan.digital/mlx-vs-coreml-on-apple-silicon-a-practical-guide-to-picking-the-right-backend-and-why-you-should-f77ddea7b27a) — related blog post
- [soniqo.audio/blog](https://soniqo.audio/blog) — blog

## Reference

- [DeepFilterNet3 paper](https://arxiv.org/abs/2305.08227)
