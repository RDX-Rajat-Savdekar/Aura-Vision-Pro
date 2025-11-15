# Aura

Aura is a visionOS application that delivers real-time, on-device speech transcription and environmental sound awareness. Built with privacy, accessibility, and immersion in mind, Aura overlays live captions and sound alerts in both a 2D floating panel and a spatial immersive interface. All processing happens on-device for speed and privacy.

<br>


## Core Features

### Real-Time, On-Device Processing
* Transcription and sound classification run locally
* No cloud dependency
* Ensures fast, private audio handling

### Intelligent Text Segmentation

* Detects natural pauses and punctuation
* Converts continuous speech into clean, readable sentences

### Multi-Language Support

* Switch languages instantly
* Supports English, Spanish, Hindi, and more

### Dual Interface Modes

* 2D floating panel for shared space
* Immersive spatial UI that follows user gaze inside RealityKit


<br>

## Key Technologies

* SwiftUI for declarative interface design
* RealityKit for spatial rendering and immersive placement
* AVFoundation for capturing microphone audio
* Speech Framework for live transcription
* SoundAnalysis Framework for environmental sound classification
* @Observable for reactive and efficient state updates


<br>

## How It Works

* Audio is captured using AVFoundation
* The stream is processed simultaneously by:
* Speech framework for transcription
* SoundAnalysis for classifying environmental sounds
* SwiftUI views are rendered into UIImages, converted into TextureResources, and displayed inside RealityKit as floating spatial elements


<br>

## Project Setup

--> Clone the repository
--> Open the project in Xcode
--> Run on the visionOS Simulator or a physical Vision Pro
--> Grant Microphone and Speech Recognition permissions on the first launch

There are no external dependencies.


<br>

## Limitations and Future Scope
### Directional Audio Awareness (Planned)
* Early code for azimuth detection exists
* UI currently does not display sound direction
* Future goal: show where a sound is coming from

### Emergency Awareness Mode (Planned)
* A major upcoming feature aims to increase personal safety at home:
* Detects urgent sounds (fire alarms, smoke detectors, breaking glass, distress cues)
* Identifies visual emergency indicators (small fires, hazardous events)
* Provides immediate instructions on what to do next
* Offers an instant Call 911 button for rapid emergency response
* This feature will help users who may not hear or notice dangerous situations, making Aura not just an accessibility tool but a safety companion.

### Expanded Sound Library
* More environmental sound classes
* Enhanced context-aware alerts


<br>

## Acknowledgements

This project was created during a hackathon hosted by:

* LA Tech Week
* USC Information Sciences Institute (ISI)
* Lovable

