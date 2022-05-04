
import AVFAudio
import Combine
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
    let audioHardwarePublisher = AudioInterfacePublisher.live
    
    let vuPublisher = PassthroughSubject<[Float], Never>()
    var inputLevels: [Float] = [0,0] {
      didSet {
        DispatchQueue.main.async {
          vuPublisher.send(inputLevels)
        }
      }
    }
    // Receive Jitter Buffer
    var audioTransProps: AudioTransportDetails = .stereoNormal
    let jitterBuffer = NetworkBuffer(
      capacity: ApiConsts.defaultJitterBuffer,
      blockSize: Int(audioTransProps.opusPacketSize.rawValue)
    )
    let underrunPublisher = PassthroughSubject<BufferState, Never>()
    var bufferState: BufferState = .normal {
      willSet {
        if newValue != bufferState {
          underrunPublisher.send(newValue)
        }
      }
    }
    
    var sendAudioPacket: ((Data) -> Void)?
   
    var inputInterface = AudioInterface.InterfaceSelection.systemDefault
    var inputChannelMapping: [Int]?
    var outputInterface = AudioInterface.InterfaceSelection.systemDefault
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
    // Connect the network source to the output
    avEngine.connect(
      networkAudioSource.avSourceNode,
      to: avEngine.mainMixerNode,
      fromBus: 0, toBus: 0,
      format: nil
    )
    
    // Build input mixer (input and reverb effects)
    let inputMixerNode = AVAudioMixerNode()
    avEngine.attach(inputMixerNode)

    let reverbNode = AVAudioUnitReverb()
    avEngine.attach(reverbNode)
    avEngine.connect(reverbNode, to: inputMixerNode,
                     format: avEngine.inputNode.outputFormat(forBus: 0)
    )
    reverbNode.loadFactoryPreset(.cathedral)
    reverbNode.wetDryMix = 0

    let connectionPoints = [
      AVAudioConnectionPoint(node: reverbNode, bus: 0),
      AVAudioConnectionPoint(node: inputMixerNode,
                             bus: inputMixerNode.nextAvailableInputBus)
    ]
    avEngine.connect(avEngine.inputNode, to: connectionPoints,
                     fromBus: 0,
                     format: avEngine.inputNode.outputFormat(forBus: 0)
    )
        
    // Add the network transmitter
    let networkAudioSender = JamulusNetworkSender(
      inputFormat: inputMixerNode.outputFormat(forBus: 0),
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
    
    var cancelables = Set<AnyCancellable>()
    audioHardwarePublisher.reasonPublisher
      .sink(
        receiveValue: { reason in
          print(reason)
//          networkAudioSource.outputFormat = avEngine.outputNode.inputFormat(forBus: 0)
        }
      )
      .store(in: &cancelables)
    
    
    return JamulusAudioEngine(
      recordingAllowed: {
#if os(iOS)
        return avAudSession.recordPermission == .granted
#else
        return true
#endif
      },
      requestRecordingPermission: { callback in
#if os(iOS)
        avAudSession.requestRecordPermission { callback($0) }
#endif
      },
      interfacePublisher: audioHardwarePublisher.interfaces,
      setAudioInputInterface: { inputInterface = $0; inputChannelMapping = $1 },
      setAudioOutputInterface: { outputInterface = $0; outputChannelMapping = $1 },
      inputLevelPublisher: vuPublisher.eraseToAnyPublisher(),
      bufferState: underrunPublisher.eraseToAnyPublisher(),
      muteInput: { networkAudioSender.inputMuted = $0 },
      start: { transportDetails, sendFunc in
        
        audioTransProps = transportDetails
        networkAudioSource.transportProps = audioTransProps
        networkAudioSender.transportProps = audioTransProps
        jitterBuffer.reset(
          blockSize: Int(audioTransProps.opusPacketSize.rawValue)
        )
        sendAudioPacket = sendFunc
        
        do {
#if os(iOS)
          try avAudSession.setActive(true, options: .notifyOthersOnDeactivation)
          try setIosAudioInterface(interface: inputInterface, session: avAudSession)
          try configureAvAudio(transProps: audioTransProps)
          print("Pref rate: \(avAudSession.preferredSampleRate), actual: \(avAudSession.sampleRate)")
#elseif os(macOS)
          try setMacOsAudioInterfaces(input: inputInterface,
                                      output: outputInterface,
                                      avEngine: avEngine)
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
            if engineActive { try avEngine.start() }
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

func setIosAudioInterface(interface: AudioInterface.InterfaceSelection,
                          session: AVAudioSession) throws {
  switch interface {
    
  case .specific(let id):
    guard let found = session.currentRoute.inputs
      .first(where: { $0.portName == id }) else {
      throw JamulusError.invalidAudioConfiguration
    }
    // Must be called with an active session
    try session.setPreferredInput(found)
    
  case .systemDefault:
    try session.setPreferredInput(nil)
  }
}
#endif

#if os(macOS)

func configureAudio(audioTransProps: AudioTransportDetails,
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

func setMacOsAudioInterfaces(input: AudioInterface.InterfaceSelection,
                             output: AudioInterface.InterfaceSelection,
                             avEngine: AVAudioEngine) throws {
  if let inUnit = avEngine.inputNode.audioUnit {
    switch input {
    case .specific(let id):
      try setAudioDevice(id: id, forAU: inUnit)
     
    case .systemDefault:
      let systemId = try getSystemAudioDeviceId(forInput: true)
      try setAudioDevice(id: systemId, forAU: inUnit)
    }
  }
//  if let outUnit = avEngine.outputNode.audioUnit {
//    try throwIfError(AudioUnitInitialize(outUnit))
//    switch output {
//    case .specific(let id):
//      try setAudioDevice(id: id, forAU: outUnit)
//      
//    case .systemDefault:
//      let systemId = try getSystemAudioDeviceId(forInput: false)
//      try setAudioDevice(id: systemId, forAU: outUnit)
//      break
//    }
//  }
}

#endif
