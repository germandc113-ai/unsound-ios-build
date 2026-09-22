import SwiftUI

struct DeviceSyncView: View {
    @ObservedObject var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var pairingCode = ""

    var body: some View {
        NavigationStack {
            ZStack {
                USBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statusCard
                        pairingCard
                        howToCard
                        limitsCard
                        BrandFooter()
                            .padding(.top, 6)
                    }
                    .padding(18)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("WINDOWS LINK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .onAppear {
            if host.isEmpty { host = sync.lastHost }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(sync.isPaired ? Color.green : USTheme.accent)
                    .frame(width: 10, height: 10)
                    .shadow(color: (sync.isPaired ? Color.green : USTheme.accent).opacity(0.65), radius: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.text(sync.isPaired ? "CONNECTED" : "NOT CONNECTED"))
                        .font(.headline)
                    Text(AppLocalization.text(sync.status))
                        .font(.caption)
                        .foregroundStyle(USTheme.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "desktopcomputer")
                    .font(.title2.bold())
                    .foregroundStyle(sync.isPaired ? .green : USTheme.accent)
            }

            if sync.isPaired {
                HStack {
                    Label(sync.serverName, systemImage: "desktopcomputer")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(sync.connectedDeviceCount) DEVICES")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(USTheme.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        sync.syncLibraryNow()
                    } label: {
                        Label("SYNC LIBRARY", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .usGlass(RoundedRectangle(cornerRadius: 15, style: .continuous), interactive: true)
                    }
                    .buttonStyle(USPressStyle())

                    Button(role: .destructive) {
                        sync.disconnect()
                    } label: {
                        Label("DISCONNECT", systemImage: "xmark")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.red.opacity(0.13), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(USPressStyle())
                }
            }
        }
        .padding(17)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.white.opacity(0.012))
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PAIR THIS IPHONE")
                .font(.headline)

            Text("Each iPhone can play independently. Windows controls only the selected device unless SYNC ALL is pressed.")
                .font(.caption)
                .foregroundStyle(USTheme.secondary)

            VStack(alignment: .leading, spacing: 7) {
                Text("THIS DEVICE NAME")
                    .font(.caption2.bold())
                    .foregroundStyle(USTheme.secondary)
                HStack(spacing: 8) {
                    TextField("Example: Adrian iPhone", text: $sync.deviceName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.08)))

                    Button("SAVE") {
                        sync.saveDeviceName(sync.deviceName)
                    }
                    .font(.caption.bold())
                    .buttonStyle(USPressStyle())
                    .padding(.horizontal, 4)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("WINDOWS IP")
                    .font(.caption2.bold())
                    .foregroundStyle(USTheme.secondary)
                TextField("Example: 192.168.1.42", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.08)))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("6 DIGIT CODE")
                    .font(.caption2.bold())
                    .foregroundStyle(USTheme.secondary)
                TextField("000000", text: $pairingCode)
                    .keyboardType(.numberPad)
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .tracking(4)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.08)))
                    .onChange(of: pairingCode) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(6))
                        if filtered != newValue { pairingCode = filtered }
                    }
            }

            Button {
                sync.saveDeviceName(sync.deviceName)
                sync.connect(host: host, pairingCode: pairingCode)
            } label: {
                HStack {
                    Image(systemName: "link")
                    Text(AppLocalization.text(sync.isPaired ? "RECONNECT" : "PAIR WINDOWS"))
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(USPressStyle())
        }
        .padding(17)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: USTheme.accent.opacity(0.035))
    }

    private var howToCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MULTI-DEVICE CONNECTION")
                .font(.headline)

            instruction(1, "Open the Windows UnSound companion.")
            instruction(2, "Give each iPhone a clear name above, for example Adrian iPhone and Poland iPhone.")
            instruction(3, "Pair both iPhones to the same Windows companion. On another network, use a private VPN path to the Windows PC.")
            instruction(4, "Windows shows each iPhone separately, with its own library, playlists, song, seek position and audio settings.")
            instruction(5, "Choose the device that should be master and press SYNC ALL on Windows when you want every connected iPhone on the same song and position.")
        }
        .padding(17)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.white.opacity(0.012))
    }

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("MULTI-DEVICE PLAYER", systemImage: "iphone.gen3.radiowaves.left.and.right")
                .font(.subheadline.bold())
            Text("Normal Windows controls target only the selected iPhone, so connected phones can listen to completely different songs at the same time. SYNC ALL aligns only song, position and play/pause. Bass, output mode, speed, pitch, repeat, effects, library and playlists remain individual per device.")
                .font(.caption)
                .foregroundStyle(USTheme.secondary)
        }
        .padding(15)
        .background(Color.black.opacity(0.40), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.055)))
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(USTheme.accent.opacity(0.22), in: Circle())

            Text(AppLocalization.text(text))
                .font(.caption)
                .foregroundStyle(USTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}
