import SwiftUI

struct LocalDevicePickerView: View {
    @Environment(\.dismiss) private var dismiss
    
    let routerIP: String
    let excludedMACs: Set<String>
    var onSelect: (LocalNetworkDevice) -> Void
    
    @State private var devices: [LocalNetworkDevice] = []
    @State private var fetchedTotalDeviceCount: Int = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    // Retry window state
    @State private var retryDeadline: Date?
    private let silentRetryDuration: TimeInterval = 5
    private let retryDelay: TimeInterval = 1

    var body: some View {
        VStack {
            Text("Select Device")
                .font(.headline)
                .padding(.top)
            
            if isLoading {
                ProgressView("Querying Router...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                // Only shown after the silent retry window has elapsed
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Retry") {
                        Task { await beginFetchWithRetries() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if devices.isEmpty {
                Text(fetchedTotalDeviceCount > 0
                     ? "No other devices found to add."
                     : "No active devices found on the network.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(devices) { device in
                    Button {
                        onSelect(device)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.originalName)
                                    .font(.body)
                                Text(device.ipAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(device.macAddress)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
            
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 400, height: 350)
        .task {
            await beginFetchWithRetries()
        }
    }
    
    private func beginFetchWithRetries() async {
        // Start a new silent retry window
        retryDeadline = Date().addingTimeInterval(silentRetryDuration)
        await fetchDevicesSilentlyUntilDeadline()
    }
    
    private func fetchDevicesSilentlyUntilDeadline() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            devices = []
            fetchedTotalDeviceCount = 0
        }

        while true {
            do {
                let service = FritzBoxTR064Service()
                let username = (
                    UserDefaults.standard.string(forKey: "local.username")
                    ?? UserDefaults.standard.string(forKey: Config.Keys.fritzUsername)
                    ?? ""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let password = (
                    UserDefaults.standard.string(forKey: "local.password")
                    ?? UserDefaults.standard.string(forKey: Config.Keys.fritzPassword)
                    ?? ""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let activeDevices = try await service.fetchConnectedDevices(
                    routerIP: routerIP,
                    username: username,
                    password: password
                )
                let excluded = Set(excludedMACs.map(normalizedMAC))
                let filtered = activeDevices.filter { !excluded.contains(normalizedMAC($0.macAddress)) }
                await MainActor.run {
                    self.fetchedTotalDeviceCount = activeDevices.count
                    self.devices = filtered.sorted(by: { $0.originalName < $1.originalName })
                    self.isLoading = false
                    self.errorMessage = nil
                }
                return
            } catch let error as FritzBoxError {
                // If still within retry window, retry silently
                if Date() < (retryDeadline ?? .distantPast) {
                    try? await Task.sleep(for: .seconds(retryDelay))
                    continue
                } else {
                    await MainActor.run {
                        self.isLoading = false
                        switch error {
                        case .missingCredentials:
                            self.errorMessage = "Missing FritzBox credentials. Please configure them in Settings."
                        case .authenticationFailed:
                            self.errorMessage = "Authentication failed. Check your FritzBox username and password."
                        default:
                            self.errorMessage = "Failed to communicate with FritzBox: \(error)"
                        }
                    }
                    return
                }
            } catch {
                // For other errors, same strategy
                if Date() < (retryDeadline ?? .distantPast) {
                    try? await Task.sleep(for: .seconds(retryDelay))
                    continue
                } else {
                    await MainActor.run {
                        self.isLoading = false
                        self.errorMessage = "An unexpected error occurred: \(error.localizedDescription)"
                    }
                    return
                }
            }
        }
    }

    private func normalizedMAC(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: ":")
    }
}
