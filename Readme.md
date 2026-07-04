# Aura

**Live captions + environmental sound alerts on Apple Vision Pro — entirely on-device.**

Built in **24 hours** at LA Tech Week / USC ISI (Oct 2025) · **2nd place** · zero cloud dependencies.

<p align="center">
  <a href="https://www.youtube.com/watch?v=HbW9F2zjmLQ"><strong>▶ Full hackathon demo</strong></a>
  &nbsp;·&nbsp;
  <a href="https://www.youtube.com/clip/UgkxpRDpwatHZPRf5Oyjow0mAWBwYbVKn7rI"><strong>60 s clip</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/RDX-Rajat-Savdekar/Manim-DSA-SD-Concepts/tree/main/Aura/design-video"><strong>System design walkthrough</strong></a>
</p>

---

## Watch

| | Link |
|---|---|
| **Full hackathon demo** (teammates present · ~2:37) | [youtube.com/watch?v=HbW9F2zjmLQ](https://www.youtube.com/watch?v=HbW9F2zjmLQ) |
| **60-second highlight** | [youtube.com/clip/UgkxpRDpwatHZPRf5Oyjow0mAWBwYbVKn7rI](https://www.youtube.com/clip/UgkxpRDpwatHZPRf5Oyjow0mAWBwYbVKn7rI) |
| **System design video** (~9 min · Manim + VO) | [Manim-DSA-SD-Concepts / Aura/design-video](https://github.com/RDX-Rajat-Savdekar/Manim-DSA-SD-Concepts/tree/main/Aura/design-video) |

---

## Demo snapshots

Real Vision Pro footage from the hackathon — live speech, sound classification, locale hot-swap.

<p align="center">
  <img src="docs/assets/demo-live-captions.png" alt="Aura live English captions on Vision Pro" width="31%" />
  <img src="docs/assets/demo-emergency-sound.png" alt="Emergency vehicle sound detected alongside speech and whispering" width="31%" />
  <img src="docs/assets/demo-locale-swap.png" alt="Japanese locale picker with live transcription" width="31%" />
</p>

<p align="center">
  <sub><b>Left:</b> live captions &nbsp;·&nbsp; <b>Center:</b> siren → emergency vehicle alert &nbsp;·&nbsp; <b>Right:</b> locale hot-swap (EN ↔ JA)</sub>
</p>

---

## System design walkthrough

A separate **architecture postmortem** explains what we shipped, cut, and why — with Manim diagrams, Swift snippets, and hackathon B-roll.

<p align="center">
  <img src="docs/assets/design-problem-hackathon.png" alt="Manim frame — situational audio gap and hackathon scope" width="48%" />
  <img src="docs/assets/design-dual-pipeline.png" alt="Manim frame — single AVAudioEngine tap dual pipeline" width="48%" />
</p>

<p align="center">
  <img src="docs/assets/design-outro.png" alt="Manim frame — 2nd place Oct 2025 outro card" width="60%" />
</p>

<p align="center">
  <sub>From the <a href="https://github.com/RDX-Rajat-Savdekar/Manim-DSA-SD-Concepts/tree/main/Aura/design-video">design-video</a> series · source + renders in the Manim repo</sub>
</p>

---

## What it does

Deaf and hard-of-hearing users miss **situational audio** — speech in a noisy room, sirens, clapping, whispers. Aura captures mic input on Vision Pro and surfaces:

- **Live captions** (on-device Speech framework)
- **Environmental sound alerts** (on-device SoundAnalysis)
- **No audio leaves the headset** — privacy-first, no cloud ASR

One `AVAudioEngine` tap feeds both pipelines in parallel. Captions are segmented into readable sentences; classifier output is gated so labels do not flap.

---

## Core features

| Feature | Detail |
|---------|--------|
| **On-device only** | Speech + SoundAnalysis run locally — no network |
| **Dual pipeline** | Single mic tap → parallel speech + sound paths |
| **Segmentation** | Pause detection + sentence splitter for readable captions |
| **7 locales** | Hot-swap recognition language without restarting the engine |
| **2D HUD** | SwiftUI floating panel (what we demoed and shipped) |
| **Spatial HUD** | RealityKit texture-baked panel (explored; see design video) |

---

## How it works

```
Mic (AVAudioEngine tap)
  ├─► Speech framework        → live captions → SwiftUI HUD
  └─► SoundAnalysis (serial queue) → sound labels → alerts
```

- Audio captured with **AVFoundation** · processed on a **serial analysis queue** so the realtime tap never blocks
- ML callbacks bridged to **MainActor** for `@Published` UI updates
- Spatial UI path: SwiftUI views rasterized to **TextureResource** for RealityKit billboards

Key files: `MicrophoneMonitor.swift` · `ContentView.swift` · `ImmersiveView.swift`

---

## Tech stack

Swift · SwiftUI · visionOS · RealityKit · AVFoundation · Speech · SoundAnalysis · Accelerate (`vDSP`)

No external dependencies.

---

## Project setup

1. Clone this repo
2. Open `Aura.xcodeproj` in Xcode
3. Run on **visionOS Simulator** or a physical **Apple Vision Pro**
4. Grant **Microphone** and **Speech Recognition** on first launch

---

## Hackathon context

| | |
|---|---|
| **When** | Oct 2025 · ~24 h build window |
| **Event** | LA Tech Week · USC ISI · Lovable |
| **Team** | Fardeen Khan · Namratha V Patil · Rajat Savdekar |
| **Who coded** | Rajat (all Swift / pipeline) |
| **Who presented** | Teammates on camera in the [full demo](https://www.youtube.com/watch?v=HbW9F2zjmLQ) |
| **Outcome** | **2nd place** · working prototype · zero external deps |

> **Honesty:** Hackathon prototype — not production, not benchmarked. Models are Apple's on-device Core ML (integrated, not trained). Directional sound pins were explored but not shipped in the demo UI.

---

## Limitations & future scope

### Directional audio (explored, not in demo UI)
Early code computes azimuth in the audio path; UI does not show world-locked sound pins. See the [design video](https://github.com/RDX-Rajat-Savdekar/Manim-DSA-SD-Concepts/tree/main/Aura/design-video) for the rejected-alternative story.

### Emergency awareness mode (planned)
Detect urgent sounds (alarms, glass break, distress) and surface immediate guidance + optional emergency call flow.

### Expanded sound library
More environmental classes and context-aware alerts.

---

## Related repos

| Repo | What |
|------|------|
| **[Manim-DSA-SD-Concepts](https://github.com/RDX-Rajat-Savdekar/Manim-DSA-SD-Concepts)** | System design video, Manim scenes, VO pipeline |
| **Aura/design-video** | ~9 min walkthrough source ([README](https://github.com/RDX-Rajat-Savdekar/Manim-DSA-SD-Concepts/blob/main/Aura/design-video/README.md)) |

---

## Acknowledgements

Hackathon hosts: **LA Tech Week** · **USC Information Sciences Institute (ISI)** · **Lovable**
