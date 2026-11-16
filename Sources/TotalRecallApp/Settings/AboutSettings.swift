import AppKit
import Shared
import SwiftUI

/// The version, and the credit the speaker model's license asks for.
struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("TotalRecall").font(.title2.bold())
            Text("Version \(version)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Records and transcribes meetings on this Mac. Your audio and your words never leave it.")
                .multilineTextAlignment(.center)
                // Wraps to as many lines as it takes, rather than being cut short.
                .fixedSize(horizontal: false, vertical: true)
            Link(
                "github.com/kingbuzzman/totalrecall",
                destination: URL(string: "https://github.com/kingbuzzman/totalrecall")!
            )
            Divider().padding(.vertical, 4)
            Text(
                "Identify Speakers uses WeSpeaker's ResNet34-LM speaker model, trained on VoxCeleb, under the "
                    + "Creative Commons Attribution 4.0 license."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link(
                    "Model",
                    destination: URL(string: "https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM")!
                )
                Link("License", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
            }
            .font(.caption)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}
