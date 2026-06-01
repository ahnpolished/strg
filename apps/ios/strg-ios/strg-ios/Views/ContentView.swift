import SwiftUI
import PhotosUI

struct ContentView: View {
    @Environment(StrgAPIClient.self) private var apiClient
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var result: PredictionResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var serverURL: String = "http://localhost:8000"
    @State private var apiKey: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Server URL config
                VStack(spacing: 8) {
                    HStack {
                        TextField("Server URL", text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: serverURL) { _, newURL in
                                apiClient.setServerURL(newURL)
                            }
                    }
                    HStack {
                        TextField("API Key (for RunPod Serverless)", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: apiKey) { _, newKey in
                                apiClient.setAPIKey(newKey)
                            }
                    }
                }
                .padding(.horizontal)

                // Photo picker
                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("Select Workout Photo", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isLoading)

                // Status / results
                if isLoading {
                    ProgressView("Analyzing...")
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if let result = result {
                    List {
                        Section("Extracted Workout (\(result.entryCount) entries)") {
                            ForEach(result.entries) { entry in
                                EntryRow(entry: entry)
                            }
                        }

                        Section("Latency") {
                            LabeledContent("Processing time", value: "\(String(format: "%.1f", result.latencyS))s")
                        }
                    }
                    .listStyle(.insetGrouped)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("strg")
            .onChange(of: selectedPhoto) { _, newItem in
                guard let newItem else { return }
                Task { await analyzePhoto(newItem) }
            }
        }
    }

    private func analyzePhoto(_ item: PhotosPickerItem) async {
        isLoading = true
        errorMessage = nil
        result = nil

        defer { isLoading = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                errorMessage = "Failed to load photo"
                return
            }

            result = try await apiClient.predict(image: image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EntryRow: View {
    let entry: WorkoutEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.exercise)
                    .font(.headline)
                Spacer()
                if let date = entry.date {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Label("\(entry.sets)x\(entry.reps)", systemImage: "repeat")
                    .font(.subheadline)
                if let kg = entry.weightKg {
                    Label("\(String(format: "%.1f", kg)) kg", systemImage: "scalemass")
                        .font(.subheadline)
                } else if let lbs = entry.weightLbs {
                    Label("\(String(format: "%.1f", lbs)) lbs", systemImage: "scalemass")
                        .font(.subheadline)
                }
            }

            if let notes = entry.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
        .environment(StrgAPIClient())
}
