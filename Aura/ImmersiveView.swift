import SwiftUI
import RealityKit

struct ImmersiveView: View {
    @EnvironmentObject var micMonitor: MicrophoneMonitor

    // Cache last transcript/classification and texture to avoid regenerating each frame and reduce overlapping access.
    @State private var lastTranscript: String = ""
    @State private var lastClassified: String = ""
    @State private var lastHistorySnapshot: [String] = []
    @State private var cachedTranscriptTexture: TextureResource?

    // Keep a short history (most recent first) of distinct classified sounds
    @State private var soundHistory: [String] = []

    // Derived: tail lines we render (no scrolling)
    @State private var transcriptTailLines: [String] = []

    // Keep a handle to the dialog entity so we can update its material from onChange (outside RealityView.update)
    @State private var dialogEntity: ModelEntity?

    // Debounce texture updates (~10 fps)
    @State private var refreshTask: Task<Void, Never>?
    private let refreshDebounceSeconds: Double = 0.1

    // HUD/dialog tuning
    private let hudDistance: Float = 0.6       // meters in front of the user for dialog
    private let hudSmoothing: Float = 0.35     // 0..1, smaller = smoother; bumped slightly for stability
    private let hudVerticalOffset: Float = 0.25 // raise panel ~25 cm above eye/camera height
    private let floorY: Float = 1.2            // clamp panel Y so it never goes below this world height

    // Tail rendering tuning
    private let tailMaxLines: Int = 6          // how many transcript lines to show in the panel
    private let panelWidthPoints: CGFloat = 520
    private let panelHeightPoints: CGFloat = 300 // slightly taller for readability

    // Color mapping for a label
    private func colorForLabel(_ label: String) -> Color {
        let lc = label.lowercased()
        if lc.contains("siren") || lc.contains("alarm") || lc.contains("emergency_vehicle") {
            return .red
        } else if lc.contains("doorbell") {
            return .orange
        } else if lc.contains("horn") {
            return .yellow
        } else if lc.contains("speech") || lc == "speech" {
            return .green
        } else {
            return .blue
        }
    }

    // Build a transcript tail from full text.
    private func makeTranscriptTail(from fullText: String) -> [String] {
        let allLines = fullText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if allLines.isEmpty {
            return ["Listening…"]
        }
        if allLines.count <= tailMaxLines {
            return allLines
        } else {
            return Array(allLines.suffix(tailMaxLines))
        }
    }

    // SwiftUI view to render the transcript tail (no scroll) + classification history
    private func transcriptView(tailLines: [String], history: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top: Transcript (dialogue) — fixed height, no scroll
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                    Text("Transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tailLines.indices, id: \.self) { idx in
                        Text(tailLines[idx])
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 130, alignment: .bottom) // keep a consistent area; align bottom so newest sits at bottom
                .clipped()
            }

            Divider().opacity(0.35)

            // Bottom: Sound classification history (current bold/colored, previous greyed)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "ear")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                    Text("Sound")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(history.prefix(3).enumerated()), id: \.offset) { index, label in
                        let isCurrent = index == 0
                        HStack(spacing: 10) {
                            Circle()
                                .fill(isCurrent ? colorForLabel(label) : Color.secondary.opacity(0.4))
                                .frame(width: 10, height: 10)
                            Text(label.isEmpty ? "…" : label)
                                .font(isCurrent ? .headline.weight(.semibold) : .subheadline)
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .frame(width: panelWidthPoints, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 10)
        )
        .tint(.accentColor)
    }

    var body: some View {
        RealityView { content in
            // Root container
            let root = Entity()
            root.name = "Root"
            content.add(root)

            // Single dialog panel (plane) with an ImageMaterial we update with text
            let dialogSize = SIMD2<Float>(1.05, 0.62) // match visual changes (slightly wider/taller)
            let dialogPlane = MeshResource.generatePlane(width: dialogSize.x, height: dialogSize.y, cornerRadius: 0.06)
            let dialog = ModelEntity(mesh: dialogPlane, materials: [UnlitMaterial(color: .white)])
            dialog.name = "TranscriptPanel"
            root.addChild(dialog)

            // Keep reference for updates outside RealityView.update
            Task { @MainActor in
                self.dialogEntity = dialog
            }

            // Initial placement: straight ahead and a bit higher (clamped to floor)
            let initialY = max(1.65, floorY)
            dialog.setPosition([0, initialY, -(hudDistance + 0.05)], relativeTo: nil)
            faceEntityTowardOrigin(dialog)

            // Seed history with current label if present
            let initialLabel = micMonitor.classifiedSound
            if !initialLabel.isEmpty && initialLabel != "..." {
                soundHistory = [initialLabel]
                lastHistorySnapshot = soundHistory
                lastClassified = initialLabel
            }

            // Initial transcript tail + texture
            let initialTranscript = micMonitor.transcript
            lastTranscript = initialTranscript
            transcriptTailLines = makeTranscriptTail(from: initialTranscript)

            Task { @MainActor in
                await updateTranscriptTexture(tailLines: transcriptTailLines, history: soundHistory)
                if let texture = cachedTranscriptTexture {
                    var mat = UnlitMaterial()
                    mat.baseColor = .texture(texture)
                    dialog.model?.materials = [mat]
                }
            }

        } update: { content in
            guard let root = content.entities.first(where: { $0.name == "Root" }) else { return }

            // Dialog panel placement: follow camera, billboard, with vertical offset + floor clamp
            if let dialog = root.findEntity(named: "TranscriptPanel") as? ModelEntity {
                // Camera proxy from root (RealityView places root at camera)
                let camTransform = root.transformMatrix(relativeTo: nil)
                let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)

                // Forward vector (negative Z)
                var forward = -SIMD3<Float>(camTransform.columns.2.x, camTransform.columns.2.y, camTransform.columns.2.z)
                if simd_length(forward) < 0.001 {
                    forward = SIMD3<Float>(0, 0, -1)
                } else {
                    forward = simd_normalize(forward)
                }

                // Desired position: fixed distance in front, with vertical lift relative to camera Y, clamped to floor
                var desired = camPos + forward * (hudDistance + 0.05)
                let targetY = camPos.y + hudVerticalOffset
                desired.y = max(targetY, floorY)

                // Smooth movement
                let current = dialog.position(relativeTo: nil)
                let lerpT = max(0.0, min(1.0, hudSmoothing))
                let mixT = SIMD3<Float>(repeating: lerpT)
                let newPos = simd_mix(current, desired, mixT)
                dialog.setPosition(newPos, relativeTo: nil)

                // Face camera fully (split into simpler steps to aid type checker)
                let rotation = billboardRotation(fromCamera: camPos, toEntity: newPos)
                dialog.transform.rotation = rotation

                // Apply latest cached texture if any (no @State mutation here)
                if let texture = cachedTranscriptTexture {
                    var mat = UnlitMaterial()
                    mat.baseColor = .texture(texture)
                    dialog.model?.materials = [mat]
                }
            }
        }
        // Outside RealityView.update: manage state and textures safely
        .onAppear {
            scheduleDebouncedTextureRefresh()
        }
        .onChange(of: micMonitor.classifiedSound) { _, newLabel in
            guard !newLabel.isEmpty, newLabel != "..." else { return }
            if soundHistory.first != newLabel {
                var newHistory = soundHistory.filter { $0 != newLabel }
                newHistory.insert(newLabel, at: 0)
                if newHistory.count > 3 { newHistory = Array(newHistory.prefix(3)) }
                soundHistory = newHistory
            }
            lastClassified = soundHistory.first ?? ""
            scheduleDebouncedTextureRefresh()
        }
        .onChange(of: micMonitor.transcript) { _, newTranscript in
            lastTranscript = newTranscript
            transcriptTailLines = makeTranscriptTail(from: newTranscript)
            scheduleDebouncedTextureRefresh()
        }
    }

    // MARK: - Helpers

    // Simplified, explicit billboard rotation helper to keep type-checking fast.
    private func billboardRotation(fromCamera camPos: SIMD3<Float>, toEntity entityPos: SIMD3<Float>) -> simd_quatf {
        let toCam = camPos - entityPos
        let dir: SIMD3<Float>
        let len = simd_length(toCam)
        if len < 0.001 {
            dir = SIMD3<Float>(0, 0, -1)
        } else {
            dir = toCam / len
        }

        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(worldUp, dir)
        let rightLen = simd_length(right)
        if rightLen < 0.001 {
            right = simd_cross(SIMD3<Float>(1, 0, 0), dir)
        }
        right = simd_normalize(right)

        let up = simd_cross(dir, right)
        let forwardCol = -dir

        let c0 = SIMD3<Float>(right.x,     right.y,     right.z)
        let c1 = SIMD3<Float>(up.x,        up.y,        up.z)
        let c2 = SIMD3<Float>(forwardCol.x, forwardCol.y, forwardCol.z)
        let rotMatrix = float3x3(columns: (c0, c1, c2))
        return simd_quatf(rotMatrix)
    }

    private func scheduleDebouncedTextureRefresh() {
        // Cancel any pending refresh
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            // Debounce window
            try? await Task.sleep(nanoseconds: UInt64(refreshDebounceSeconds * 1_000_000_000))

            // Build texture and push it
            await updateTranscriptTexture(tailLines: transcriptTailLines, history: soundHistory)

            if let dialog = dialogEntity, let texture = cachedTranscriptTexture {
                var mat = UnlitMaterial()
                mat.baseColor = .texture(texture)
                dialog.model?.materials = [mat]
            }
        }
    }

    private func faceEntityTowardOrigin(_ entity: Entity) {
        let pos = entity.position(relativeTo: nil)
        let toOrigin = -pos
        let forward = simd_normalize(SIMD3<Float>(toOrigin.x, 0, toOrigin.z))
        let yaw = atan2f(forward.x, -forward.z)
        entity.transform.rotation = simd_quatf(angle: yaw, axis: [0, 1, 0])
    }

    // Render the SwiftUI transcript+history tail view to a UIImage for use in an UnlitMaterial texture.
    private func renderTranscriptImage(tailLines: [String], history: [String]) -> UIImage? {
        let view = transcriptView(tailLines: tailLines, history: history)

        let controller = UIHostingController(rootView: view)
        let size = CGSize(width: panelWidthPoints, height: panelHeightPoints)
        controller.view.bounds = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .clear

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }

    // Build and cache the transcript texture (always rebuild when called)
    @MainActor
    private func updateTranscriptTexture(tailLines: [String], history: [String]) async {
        guard let uiImage = renderTranscriptImage(tailLines: tailLines, history: history),
              let cgImage = uiImage.cgImage else {
            cachedTranscriptTexture = nil
            return
        }
        do {
            let texture = try TextureResource.generate(from: cgImage, options: .init(semantic: .color))
            cachedTranscriptTexture = texture
        } catch {
            cachedTranscriptTexture = nil
        }
    }
}
