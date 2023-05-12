
import AVFAudio
import Foundation
import JamulusProtocol
import Opus

extension JamulusAudioEngine {
  
  public static var live: Self {
    
    /// The opus instance supporting 128 frame encoding/decoding
    let opus: Opus.Custom! = try? Opus.Custom(
      format: opus48kFormat,
      application: .audio,
      frameSize: UInt32(2 * ApiConsts.frameSamples64)
    )
    try? opus.configureForJamulus()
    
    /// The opus instance supporting 64 frame encoding/decoding
    let opus64: Opus.Custom! = try? Opus.Custom(
      format: opus48kFormat,
      application: .audio,
      frameSize: UInt32(ApiConsts.frameSamples64)
    )
    try? opus64.configureForJamulus()
    let avEngine = AVAudioEngine()
    
#if os(iOS)
    let avAudSession = AVAudioSession.sharedInstance()
    initAvFoundation()
#endif
    let audioHardwarePublisher = AudioInterfaceProvider.live
    
    var vuContinuation: AsyncStream<[Float]>.Continuation?
    let vuLevelStream = AsyncStream<[Float]> { continuation in
      vuContinuation = continuation
    }
    var inputLevels: [Float] = [0,0] {
      didSet {
        vuContinuation?.yield(inputLevels)
      }
    }
    
    // Receive Jitter Buffer
    var audioTransProps: AudioTransportDetails = .stereoNormal
    let jitterBuffer = NetworkBuffer(
      capacity: ApiConsts.defaultJitterBuffer,
      blockSize: Int(audioTransProps.opusPacketSize.rawValue)
    )
    
    var stateContinuation: AsyncStream<BufferState>.Continuation?
    let bufferStateStream = AsyncStream<BufferState> { continuation in
      stateContinuation = continuation
    }
    var bufferState: BufferState = .normal {
      willSet {
        if newValue != bufferState {
          stateContinuation?.yield(newValue)
        }
      }
    }
    
    var sendAudioPacket: ((Data) -> Void)?
   
    var inputInterface: AudioInterface? = .defaultInInterface
    var inputChannelMapping: [Int]?
    var outputInterface: AudioInterface? = .defaultOutInterface
    var outputChannelMapping: [Int]?

    
    let networkAudioSource = JamulusNetworkReceiver(
      transportDetails: audioTransProps,
      opus: opus,
      opus64: opus64,
      dataReceiver: { jitterBuffer },
      updateBufferState: { bufferState = $0 }
    )
    
    // Attach to the engine
    avEngine.attach(networkAudioSource.avSourceNode)
    // Connect the network source to the main mixer
    avEngine.connect(
      networkAudioSource.avSourceNode,
      to: avEngine.mainMixerNode,
      fromBus: 0, toBus: 0,
      format: nil
    )
    
    let inputSampleRate = avEngine.inputNode.outputFormat(forBus: 0).sampleRate
    let mixerOutFormat = AVAudioFormat(
      standardFormatWithSampleRate: inputSampleRate, channels: 2
    )
    
    // Build input mixer (input and reverb effects)
    let inputMixerNode = AVAudioMixerNode()
    avEngine.attach(inputMixerNode)
    let reverbNode = AVAudioUnitReverb()
    avEngine.attach(reverbNode)

    avEngine.connect(avEngine.inputNode, to: inputMixerNode, format: nil)
    avEngine.connect(inputMixerNode, to: reverbNode, format: mixerOutFormat)
    inputMixerNode.outputVolume = 1
    
    // Add the network transmitter
    let networkAudioSender = JamulusNetworkSender(
      inputFormat: mixerOutFormat!,
      transportDetails: audioTransProps,
      opus: opus,
      opus64: opus64,
      sendAudioPacket: { sendAudioPacket?($0) },
      setVuLevels: { inputLevels = $0 }
    )
    
    avEngine.attach(networkAudioSender.avSinkNode)
    avEngine.connect(inputMixerNode,
                     to: networkAudioSender.avSinkNode,
                     format: nil)
    avEngine.prepare()
    
//    var cancellables = Set<AnyCancellable>()
//    audioHardwarePublisher.reasonPublisher
//      .sink(
//        receiveValue: { reason in
//          print(reason)
////          networkAudioSource.outputFormat = avEngine.outputNode.inputFormat(forBus: 0)
//        }
//      )
//      .store(in: &cancellables)
    
    
    return JamulusAudioEngine(
      recordingAllowed: {
#if os(iOS)
        return avAudSession.recordPermission == .granted
#else
        return true
#endif
      },
      requestRecordingPermission: {
#if os(iOS)
        await withCheckedContinuation { continuation in
          avAudSession.requestRecordPermission {
            continuation.resume(returning: $0)
          }
        }
#else
        return true
#endif
      },
      interfacesAvailable: audioHardwarePublisher.interfaces,
      setAudioInputInterface: { inputInterface = $0; inputChannelMapping = $1 },
      setAudioOutputInterface: { outputInterface = $0; outputChannelMapping = $1 },
      inputVuLevels: vuLevelStream,
      bufferState: bufferStateStream,
      muteInput: { networkAudioSender.inputMuted = $0 },
      start: { transportDetails, sendFunc in
        
        audioTransProps = transportDetails
        networkAudioSource.transportProps = audioTransProps
        networkAudioSender.transportProps = audioTransProps
        jitterBuffer.reset(
          blockSize: Int(audioTransProps.opusPacketSize.rawValue)
        )
        sendAudioPacket = { audioData in Task { await sendFunc(audioData) } }
        
        do {
#if os(iOS)
          try avAudSession.setActive(true, options: .notifyOthersOnDeactivation)
          try setIosAudioInterface(interface: inputInterface, session: avAudSession)
          try configureAvAudio(transProps: audioTransProps)
          print("Pref rate: \(avAudSession.preferredSampleRate), actual: \(avAudSession.sampleRate)")
#elseif os(macOS)
          try configureAudio(audioTransProps: audioTransProps, avEngine: avEngine)
#endif
          try avEngine.start()
          networkAudioSender.inputFormat = inputMixerNode.outputFormat(forBus: 0)
        } catch {
          return JamulusError.avAudioError(error as NSError)
        }
        return nil
      },
      stop: {
        do {
          avEngine.stop()
#if !os(macOS)
          try avAudSession.setActive(false)
#endif
          sendAudioPacket = nil
          inputLevels = [Float](
            repeating: 0,
            count: avEngine.inputNode.auAudioUnit.channelMap?.count ?? 2
          )
        } catch {
          return JamulusError.avAudioError(error as NSError)
        }
        return nil
      },
      setReverbLevel: { reverbNode.wetDryMix = $0 },
      setReverbType: { reverbNode.loadFactoryPreset($0) },
      handleAudioFromNetwork: jitterBuffer.write(_:),
      setNetworkBufferSize: {
        jitterBuffer.resizeTo(
          newCapacity:$0,
          blockSize: Int(audioTransProps.opusPacketSize.rawValue))
      },
      setTransportProperties: { transportDetails in
        let engineActive = avEngine.isRunning
        do {
          if transportDetails.opusPacketSize != audioTransProps.opusPacketSize {
            jitterBuffer.reset(blockSize: Int(transportDetails.opusPacketSize.rawValue))
          }
          if transportDetails.codec != audioTransProps.codec {
            if engineActive { avEngine.pause() }
#if os(iOS)
            try configureAvAudio(transProps: transportDetails)
#elseif os(macOS)
            try configureAudio(audioTransProps: transportDetails, avEngine: avEngine)
#endif
            if !engineActive { try avEngine.start() }
          }
        } catch {
          return JamulusError.avAudioError(error as NSError)
        }
        audioTransProps = transportDetails
        networkAudioSource.transportProps = audioTransProps
        networkAudioSender.transportProps = audioTransProps
        return nil
      }
    )
  }
}

#if os(iOS)
func initAvFoundation() {
  let avSession = AVAudioSession.sharedInstance()
  do {
    try avSession.setCategory(
    .playAndRecord,
    mode: .measurement,
    options: [
      .allowAirPlay,
      .allowBluetoothA2DP,
      .duckOthers,
      .defaultToSpeaker,
      .overrideMutedMicrophoneInterruption
    ]
  )
  } catch {
    print("Error initializing AVFoundation: \(error)")
  }
}

func configureAvAudio(transProps: AudioTransportDetails) throws {
  // Configure AVAudioSession
  let avSession = AVAudioSession.sharedInstance()

  let bufferDuration = TimeInterval(
    Float64(transProps.frameSize) /
    ApiConsts.sampleRate48kHz
  )
  // Try to set session to 48kHz
  try avSession.setPreferredSampleRate(Double(ApiConsts.sampleRate48kHz))
  try avSession.setPreferredIOBufferDuration(bufferDuration)
}

func setIosAudioInterface(interface: AudioInterface?,
                          session: AVAudioSession) throws {
  
  guard let found = session.currentRoute.inputs
    .first(where: { $0.portName == interface?.id }) else {
    throw JamulusError.invalidAudioConfiguration
  }
  // Must be called with an active session
  try session.setPreferredInput(found)
}
#endif

#if os(macOS)

private func configureAudio(audioTransProps: AudioTransportDetails,
                    avEngine: AVAudioEngine) throws {
  let frameSizeMultiplier: UInt16 = audioTransProps.codec == .opus64 ? 1 : 2
  var bufferFrameSize = UInt32(audioTransProps.frameSize * frameSizeMultiplier)
  try throwIfError(
    setBufferFrameSize(
      for: avEngine.outputNode.audioUnit, to: &bufferFrameSize
    )
  )
  try throwIfError(
    setBufferFrameSize(
      for: avEngine.inputNode.audioUnit, to: &bufferFrameSize
    )
  )
}

#endif
