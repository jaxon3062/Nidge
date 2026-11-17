import SwiftUI

struct OnboardingView: View {
    var done: () -> Void
    @State private var photosDenied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Nidge")
                    .font(.largeTitle.bold())
                Text("Download photos from your camera to Apple Photos. Works with Nikon Z cameras.")
                    .foregroundStyle(.secondary)

                step("1", "On the camera, open the Network menu, choose Connect to smart device, then Wi-Fi connection.")
                step("2", "On this iPhone, open Settings, then Wi-Fi, and join the network the camera shows. You only type the password once.")
                step("3", "Come back here. Nidge asks to find devices on your local network; allow it so it can reach the camera.")
                step("4", "Allow Nidge to add photos to your library. It cannot see or change the photos already there.")

                if photosDenied {
                    Text("Photos access was not granted. You can allow it later in Settings, under Privacy & Security, Photos.")
                        .foregroundStyle(.red)
                }
                Button {
                    Task {
                        photosDenied = !(await PhotosWriter.requestAccess())
                        if !photosDenied { done() }
                    }
                } label: {
                    Text("Allow Photos access").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                if photosDenied {
                    Button("Continue without Photos access", action: done)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number).font(.headline).foregroundStyle(.tint)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}
