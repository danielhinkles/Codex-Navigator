import SwiftUI

struct ComposerAudioControls:View {
    @EnvironmentObject var model:NavigatorModel
    @ObservedObject var audio:ComposerAudio
    @ObservedObject var store:ComposerStore
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                if audio.mode.isEmpty {
                    Button {
                        let key=store.state.taskKey ?? ""
                        audio.dictate(key:key) {text in store.appendDictation(text,to:key)}
                    } label: {Label("Dictate",systemImage:"mic")}
                    .disabled(store.submitting || (store.state.taskKey ?? "").isEmpty)
                    .help("Dictate a prompt using macOS speech recognition; review it before sending.")

                } else {
                    if audio.mode=="voice" {
                        Label("Voice chat · microphone " + (audio.muted ? "muted" : "on"),systemImage:"waveform")
                        Button(audio.muted ? "Unmute" : "Mute") {audio.muted.toggle()}
                    } else {
                        Label(audio.mode=="dictating" ? "Listening…" : audio.mode=="connecting" ? "Connecting voice…" : "Waiting for microphone permission…",systemImage:"mic")
                    }
                    Spacer()
                    Button(audio.mode=="dictating" ? "Done" : "End") {audio.stop()}
                }
            }.font(.callout)
            if !audio.transcript.isEmpty {Text(audio.transcript).font(.callout).foregroundStyle(.secondary).lineLimit(3)}
            let error=audio.error
            if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)}
        }
    }
}
