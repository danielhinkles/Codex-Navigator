import SwiftUI
import AVFoundation
import Speech

struct ComposerVoicePacket:Decodable {
    let taskKey,voiceID:String
    let audio:ComposerAudioChunk
}
struct ComposerAudioChunk:Decodable {
    let data:String
    let sampleRate:Double
    let numChannels:Int
}

/// Microphone access happens only after a button press. Packets carry a task
/// and session identity so delayed audio can never reach a different task.
final class ComposerAudio:ObservableObject {
    @Published var mode=""
    @Published var transcript=""
    @Published var error=""
    @Published var muted=false
    private var engine:AVAudioEngine?
    private var playback:AVAudioEngine?
    private var player:AVAudioPlayerNode?
    private var recognition:SFSpeechRecognitionTask?
    private var request:SFSpeechAudioBufferRecognitionRequest?
    private var generation=UUID()
    private var taskKey=""
    private var voiceID=""
    private var send:(([String:Any])->Void)?
    private var commit:((String)->Void)?
    private var playbackRate:Double=0
    private var queuedFrames=0
    private var playbackGeneration=UUID()

    func dictate(key:String,commit:@escaping(String)->Void) {
        guard mode.isEmpty else {return}
        mode="permission";error="";transcript="";taskKey=key;self.commit=commit
        let token=UUID();generation=token
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self,self.generation==token else {return}
                guard status == .authorized else {self.fail("Allow Speech Recognition for Navigator in System Settings → Privacy & Security.");return}
                self.microphone(token:token) {self.startDictation(token:token)}
            }
        }
    }
    private func microphone(token:UUID,ready:@escaping()->Void) {
        AVCaptureDevice.requestAccess(for:.audio) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self,self.generation==token else {return}
                guard allowed else {self.fail("Allow Microphone access for Navigator in System Settings → Privacy & Security.");return}
                ready()
            }
        }
    }
    private func startDictation(token:UUID) {
        guard let recognizer=SFSpeechRecognizer(),recognizer.isAvailable else {fail("Dictation is unavailable for the current language.");return}
        let request=SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults=true
        self.request=request
        do {
            let engine=AVAudioEngine();self.engine=engine
            let input=engine.inputNode,format=input.outputFormat(forBus:0)
            guard format.sampleRate>0,format.channelCount>0 else {fail("No microphone is available.");return}
            input.installTap(onBus:0,bufferSize:2048,format:format) {buffer,_ in request.append(buffer)}
            mode="dictating"
            recognition=recognizer.recognitionTask(with:request) { [weak self] result,failure in
                DispatchQueue.main.async {
                    guard let self,self.generation==token else {return}
                    if let result {self.transcript=result.bestTranscription.formattedString}
                    if result?.isFinal == true {self.finishDictation()}
                    else if let failure {self.error=failure.localizedDescription;self.finishDictation()}
                }
            }
            engine.prepare();try engine.start()
        } catch {fail("Could not start dictation: "+error.localizedDescription)}
    }
    func finishDictation() {
        let text=transcript,callback=commit
        stopLocal()
        if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {callback?(text)}
        transcript=""
    }
    func startVoice(key:String,send:@escaping([String:Any])->Void) {
        guard mode.isEmpty else {return}
        mode="permission";error="";taskKey=key;self.send=send
        let token=UUID();generation=token;voiceID=token.uuidString
        microphone(token:token) {
            self.mode="connecting"
            send(["action":"composerVoiceStart","taskKey":key,"voiceID":self.voiceID])
        }
    }
    func accept(_ state:ComposerState) {
        guard !mode.isEmpty else {return}
        if state.taskKey != taskKey {stop();return}
        if state.status=="disconnected" && !voiceID.isEmpty {stop();error="Voice disconnected. Reconnect the task before starting voice again.";return}
        guard !voiceID.isEmpty,state.voiceID==voiceID else {return}
        if state.voiceStatus=="active" && mode=="connecting" {startVoiceCapture()}
        if ["idle","error"].contains(state.voiceStatus ?? "") {
            let message=state.voiceError ?? ""
            stopLocal()
            if !message.isEmpty {error=message}
        }
        if state.voiceStatus=="stopping" {stopLocal()}
    }
    private func startVoiceCapture() {
        do {
            let engine=AVAudioEngine();self.engine=engine
            let input=engine.inputNode
            // Voice processing provides echo cancellation for speaker playback.
            try input.setVoiceProcessingEnabled(true)
            let source=input.outputFormat(forBus:0)
            guard source.sampleRate>0,source.channelCount>0,
                  let target=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:24000,channels:1,interleaved:true),
                  let converter=AVAudioConverter(from:source,to:target) else {fail("No compatible microphone is available.");return}
            let token=generation
            input.installTap(onBus:0,bufferSize:4800,format:source) { [weak self] buffer,_ in
                let capacity=AVAudioFrameCount(ceil(Double(buffer.frameLength)*24000/source.sampleRate)+8)
                guard let output=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:capacity) else {return}
                var supplied=false
                var conversionError:NSError?
                converter.convert(to:output,error:&conversionError) {_,status in
                    if supplied {status.pointee = .noDataNow;return nil}
                    supplied=true;status.pointee = .haveData;return buffer
                }
                guard conversionError==nil,output.frameLength>0,let samples=output.int16ChannelData else {return}
                let encoded=Data(bytes:samples[0],count:Int(output.frameLength)*2).base64EncodedString()
                DispatchQueue.main.async {
                    guard let self,self.generation==token,self.mode=="voice",!self.muted else {return}
                    self.send?(["action":"composerVoiceAudio","taskKey":self.taskKey,"voiceID":self.voiceID,
                                "audio":["data":encoded,"sampleRate":24000,"numChannels":1,"samplesPerChannel":Int(output.frameLength)]])
                }
            }
            engine.prepare();try engine.start();mode="voice";muted=false
        } catch {fail("Could not start microphone: "+error.localizedDescription)}
    }
    func receive(_ packet:ComposerVoicePacket) {
        guard mode=="voice",packet.taskKey==taskKey,packet.voiceID==voiceID else {return}
        let audio=packet.audio
        guard audio.numChannels==1,audio.sampleRate>=8000,audio.sampleRate<=96000,
              let data=Data(base64Encoded:audio.data),!data.isEmpty,data.count%2==0,data.count<=480000 else {return}
        do {
            if playbackRate != audio.sampleRate || playback==nil {
                player?.stop();playback?.stop()
                playbackGeneration=UUID();queuedFrames=0
                let engine=AVAudioEngine(),node=AVAudioPlayerNode()
                let format=AVAudioFormat(standardFormatWithSampleRate:audio.sampleRate,channels:1)!
                engine.attach(node);engine.connect(node,to:engine.mainMixerNode,format:format)
                try engine.start();node.play()
                playback=engine;player=node;playbackRate=audio.sampleRate
            }
            guard queuedFrames<Int(audio.sampleRate*10) else {fail("Voice playback fell behind. Please reconnect voice chat.");return}
            let frames=data.count/2
            let format=AVAudioFormat(standardFormatWithSampleRate:audio.sampleRate,channels:1)!
            guard let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)),let samples=buffer.floatChannelData else {return}
            buffer.frameLength=AVAudioFrameCount(frames)
            data.withUnsafeBytes {raw in
                for i in 0..<frames {
                    let value=raw.loadUnaligned(fromByteOffset:i*2,as:Int16.self)
                    samples[0][i]=Float(Int16(littleEndian:value))/32768
                }
            }
            queuedFrames+=frames
            let token=playbackGeneration
            player?.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self,self.playbackGeneration==token else {return}
                    self.queuedFrames=max(0,self.queuedFrames-frames)
                }
            }
        } catch {fail("Could not play voice audio: "+error.localizedDescription)}
    }
    func stop() {
        if voiceID.isEmpty {finishDictation()}
        else {
            send?(["action":"composerVoiceStop","taskKey":taskKey,"voiceID":voiceID])
            stopLocal()
        }
    }
    func transportFailed(_ message:String,for session:String) {guard voiceID==session else {return};stopLocal();error=message}
    private func fail(_ message:String) {stop();error=message}
    private func stopLocal() {
        generation=UUID()
        if let engine {engine.inputNode.removeTap(onBus:0);engine.stop()}
        engine=nil
        request?.endAudio();recognition?.cancel();request=nil;recognition=nil
        player?.stop();playback?.stop();player=nil;playback=nil;playbackRate=0
        playbackGeneration=UUID();queuedFrames=0
        mode="";voiceID="";send=nil;commit=nil;muted=false
    }
}
