import SwiftUI

@main
struct PipApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var model = GuideModel()
    @State private var showDebug = false
    @State private var showSteps = false
    @State private var showMemory = false

    var body: some View {
        ZStack {
            ARContainer(controller: model.ar).ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Text(model.watching && model.phase == .listening ? (model.language == "Dutch" ? "Ik kijk mee…" : "Watching your work…") : model.phase.label)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                    Spacer()
                    Button(model.language == "Dutch" ? "NL" : "EN") {
                        model.language = model.language == "Dutch" ? "English" : "Dutch"
                    }
                    .buttonStyle(.bordered).tint(.white)
                    Button { showMemory = true } label: { Image(systemName: "brain.head.profile") }
                        .buttonStyle(.bordered).tint(.white)
                        .accessibilityLabel("Memory")
                    Button { showDebug.toggle() } label: { Image(systemName: "eye") }
                        .buttonStyle(.bordered).tint(.white)
                    Button { model.resetConversation() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.bordered).tint(.white)
                }
                .padding(.horizontal)

                if let preparing = model.preparing {
                    Label(preparing, systemImage: "doc.text.magnifyingglass")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                if let task = model.taskView { taskCard(task) }
                if !model.shopping.isEmpty { shoppingCard }
                if showDebug { debugPanel }
                StatusHUD(ar: model.ar)

                Spacer()

                if !model.heard.isEmpty {
                    Text("“\(model.heard)”")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal)
                }
                if !model.caption.isEmpty {
                    Text(model.caption)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)
                }
                micButton.padding(.bottom, 24)
            }
        }
        .onAppear { model.start() }
        .sheet(isPresented: $showMemory) { MemorySheet(model: model, memory: model.memory, ar: model.ar) }
        .sheet(isPresented: $showSteps) {
            if let task = model.taskView { StepsSheet(task: task) }
        }
        .onChange(of: model.taskView?.finished ?? false) { _, finished in
            if finished { showSteps = true }
        }
    }

    /// Mute and unmute while listening; stop Pip while it looks or talks.
    private var micButton: some View {
        let busy = model.phase == .speaking || model.phase == .looking
        let icon = busy ? "stop.fill" : (model.muted ? "mic.slash.fill" : "mic.fill")
        let fill: Color = busy ? .white : (model.muted ? Color(white: 0.25) : .white)
        let ring: Color = model.phase == .hearing ? .green : .white.opacity(0.4)
        return Button { model.micTapped() } label: {
            ZStack {
                Circle().stroke(ring, lineWidth: model.phase == .hearing ? 6 : 2).frame(width: 96, height: 96)
                Circle().fill(fill).frame(width: 80, height: 80)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(model.muted && !busy ? .white : .black)
            }
            .shadow(radius: 8)
        }
        .accessibilityLabel(busy ? "Stop Pip" : (model.muted ? "Unmute" : "Mute"))
    }

    /// The shopping list: what is in the basket and what is still to get.
    private var shoppingCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("\(model.shopping.filter(\.inBasket).count)/\(model.shopping.count)", systemImage: "cart")
                    .font(.headline.monospacedDigit())
                Spacer()
            }
            ForEach(model.shopping) { item in
                Label(item.name, systemImage: item.inBasket ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(item.inBasket ? .green : .white)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    /// The current step at a glance; tap for every step and its status.
    private func taskCard(_ task: GuideModel.TaskView) -> some View {
        Button { showSteps = true } label: {
            HStack(spacing: 10) {
                Text(task.finished ? "✓" : "\(min(task.index + 1, task.steps.count))/\(task.steps.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(Color(red: 0.55, green: 1, blue: 1), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Text(task.finished ? "Done" : (task.steps.indices.contains(task.index) ? task.steps[task.index].text : ""))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "list.bullet").foregroundStyle(.white.opacity(0.8))
            }
            .padding(10)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal)
        .accessibilityLabel("Steps")
    }

    /// When this build was made (the app binary's date), to check that an update arrived.
    static let buildStamp: String = {
        let date = Bundle.main.executableURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date } ?? Date()
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return "Build " + f.string(from: date)
    }()

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.buildStamp).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
            debugTrace
        }
    }

    private var debugTrace: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.trace.suffix(30).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

/// Hosts the ARView with the cue overlay on top.
struct ARContainer: UIViewRepresentable {
    let controller: ARController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        controller.arView.translatesAutoresizingMaskIntoConstraints = false
        controller.overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.arView)
        // EdgeTAM's mask (when shown) over the camera image, under Pip's own outlines.
        container.addSubview(controller.edgeTAM.view)
        container.addSubview(controller.overlay)
        controller.edgeTAM.view.translatesAutoresizingMaskIntoConstraints = false
        for v in [controller.arView, controller.edgeTAM.view, controller.overlay] as [UIView] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// What the running tests measure (EdgeTAM's speed, the home map's state), one line each.
struct StatusHUD: View {
    @ObservedObject var ar: ARController

    var body: some View {
        let lines = ar.statusLines.sorted { $0.key < $1.key }.map(\.value)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }
}

/// Every step with how it was checked, the source, and at the end the report to share.
struct StepsSheet: View {
    let task: GuideModel.TaskView

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(task.steps) { step in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: step.state)
                                .foregroundStyle(step.state.hasPrefix("checkmark") ? .green : (step.id == task.index && !task.finished ? .cyan : .secondary))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(step.id + 1). \(step.text)")
                                if let ref = step.sourceRef { Text(ref).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: {
                    Text(task.source)
                }
                if let report = task.report {
                    Section("Summary") {
                        Text(report).font(.footnote.monospaced()).textSelection(.enabled)
                        ShareLink(item: report) { Label("Share the summary", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Everything Pip remembers, where it came from, and a way to delete it.
struct MemorySheet: View {
    @ObservedObject var model: GuideModel
    @ObservedObject var memory: SpaceMemory
    @ObservedObject var ar: ARController
    @AppStorage(EdgeTAMFollower.enabledKey) private var edgeTAMTest = true
    @AppStorage(EdgeTAMFollower.maskKey) private var edgeTAMMask = false
    @AppStorage(Diagnostics.key) private var testRecord = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Remember across sessions", isOn: Binding(get: { memory.consent == true }, set: { model.setConsent($0) }))
                } footer: {
                    Text("Stored only on this iPhone: the room map, the places you showed Pip, and facts about your devices.")
                }
                Section("Places") {
                    if ar.places.isEmpty { Text("Show Pip something and say what it is.").foregroundStyle(.secondary) }
                    ForEach(ar.places.values.sorted { $0.created < $1.created }) { place in
                        Label(place.name, systemImage: "mappin.circle")
                            .swipeActions { Button("Forget", role: .destructive) { model.forget(place: place.id) } }
                    }
                }
                Section("Facts") {
                    ForEach(model.facts.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading) {
                            Text(model.facts[key]?.value ?? "")
                            Text("\(key) · \(model.facts[key]?.source == "seen" ? "seen" : "you said so")").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Forget", role: .destructive) { model.forget(fact: key) } }
                    }
                }
                Section {
                    Button("Forget everything", role: .destructive) { model.forgetEverything() }
                }
                Section {
                    Toggle("Follow objects with EdgeTAM", isOn: $edgeTAMTest)
                    Toggle("Show EdgeTAM's mask (cyan)", isOn: $edgeTAMMask)
                    Toggle("Keep a test record", isOn: Binding(get: { testRecord }, set: { testRecord = $0; Diagnostics.setEnabled($0) }))
                    ForEach(ar.statusLines.sorted { $0.key < $1.key }.map(\.value), id: \.self) { Text($0).font(.caption.monospaced()) }
                } header: {
                    Text("Tests")
                } footer: {
                    Text("The room is mapped on its own while you use Pip, and recognised at the next start. The test record (every look, EdgeTAM's frames, what you saw, the logs) stays on this iPhone, out of backups; switching it off deletes it.")
                }
            }
            .navigationTitle("What Pip remembers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
