
import AVFoundation
import Combine
import Foundation
import Opus
import JamulusProtocol

extension JamulusAudioEngine {
  
  public static var live: Self {
    
#if os(iOS)
    let avAudSession = AVAudioSession.sharedInstance()
    initAvFoundation()
#endif
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
    
    let avEngine = AVAudioEngine()
    var inputInterface = AudioInterface.InterfaceSelection.systemDefault
    var inputChannelMapping: [Int]?
    var outputInterface = AudioInterface.InterfaceSelection.systemDefault
    var outputChannelMapping: [Int]?
    
    let inputFormat = avEngine.inputNode.inputFormat(forBus: 0)
    let converter = AVAudioConverter(from: inputFormat, to: opus48kFormat)
    var inputMuted = true
    
    let audioSource = audioSourceNode(
      dataSource: { jitterBuffer },
      transportDetails: { audioTransProps },
      updateBufferState: { bufferState = $0 },
      opus: opus, opus64: opus64, avEngine: avEngine
    )
    avEngine.attach(audioSource)
    
    let kUpdateInterval: UInt8 = 50
    var counter: UInt8 = 0

    /// Audio input source node. Sends PCM buffers to opus and the network
    let audioSink = AVAudioSinkNode { timestamp, frameCount, pcmBuffers in
      counter = counter &+ 1
      
      guard let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        bufferListNoCopy: pcmBuffers
      ) else {
        // Send dummy packet or the server thinks we died
        sendAudioPacket?(
          Data(repeating: 0,
               count: Int(audioTransProps.opusPacketSize.rawValue))
        )
        print("COULD NOT CREATE AUDIO")
        return noErr
      }
      
      if counter % kUpdateInterval == 0 {
        inputLevels = pcmBuffer.averageLevels
//        inputLevels = buf.decibelsByChannel.map{ $0.scaledPower(minDb: 30) }
      }

      if inputMuted { // Zero the buffer, as opus needs the packet
        let mutableBuffers = pcmBuffer.mutableAudioBufferList
        let bufListPtr = UnsafeMutableAudioBufferListPointer(&mutableBuffers.pointee)
        for buf in bufListPtr { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
      }

      // Encode and send the audio
      do {
        if pcmBuffer.format.isValidOpusPCMFormat &&
            pcmBuffer.format.channelCount == opus48kFormat.channelCount {
          compressAndSendAudio(buffer: pcmBuffer,
                               transportProps: audioTransProps,
                               sendPacket: sendAudioPacket)
        } else {
          let frameRatio = opus48kFormat.sampleRate / inputFormat.sampleRate
          if let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: opus48kFormat,
            frameCapacity: UInt32(Double(pcmBuffer.frameLength) * frameRatio)
          ) {
            var error: NSError? = nil
            
            converter?.convert(
              to: convertedBuffer, error: &error,
              withInputFrom: { _, status in
                status.pointee = .haveData
                return pcmBuffer
            })

            self.compressAndSendAudio(buffer: convertedBuffer,
                                      transportProps: audioTransProps,
                                      sendPacket: sendAudioPacket)
          } else {
            throw JamulusError.audioConversionFailed
          }
        }
      } catch {
        print(error)
        // Send dummy packet or the server thinks we died
        sendAudioPacket?(
          Data(repeating: 0,
               count: Int(audioTransProps.opusPacketSize.rawValue))
        )
      }
      return noErr
    }
    avEngine.attach(audioSink)
    
    // Connect nodes
    // Connect the input to the sink
    avEngine.connect(avEngine.inputNode, to: audioSink, fromBus: 0, toBus: 0, format: nil)
    
    // Connect the network source to the output
    avEngine.mainMixerNode.outputVolume = 0
    avEngine.connect(audioSource, to: avEngine.outputNode, format: nil)
    avEngine.prepare()
    
    //    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification )
    //      .sink { notification in
    //        if notification.userInfo[AVAudioSessionRouteChangedReasonkey]
    //      }
    
    @discardableResult
    func setOpusBitrate(audioTransProps: AudioTransportDetails) -> JamulusError? {
      // Set opus bitrate
      var err = Opus.Error.ok
      if audioTransProps.codec == .opus64 {
        err = opus64.encoderCtl(request: OPUS_SET_BITRATE_REQUEST,
                                value: audioTransProps.bitRatePerSec())
      } else {
        err = opus.encoderCtl(request: OPUS_SET_BITRATE_REQUEST,
                              value: audioTransProps.bitRatePerSec())
      }
      guard err == Opus.Error.ok else {
        return JamulusError.opusError(err.rawValue)
      }
      return nil
    }
    
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
      availableInterfaces: {
#if os(macOS)
        return macOsAudioInterfaces()
#elseif os(iOS)
        return iOsAudioInterfaces(session: avAudSession)
#else
        return []
#endif
      },
      setAudioInputInterface: { inputInterface = $0; inputChannelMapping = $1 },
      setAudioOutputInterface: { outputInterface = $0; outputChannelMapping = $1 },
      inputLevelPublisher: { vuPublisher.eraseToAnyPublisher() },
      bufferState: { underrunPublisher.eraseToAnyPublisher() },
      muteInput: { inputMuted = $0 },
      start: { transportDetails, sendFunc in
        
        audioTransProps = transportDetails
        jitterBuffer.reset(
          blockSize: Int(transportDetails.opusPacketSize.rawValue)
        )
        setOpusBitrate(audioTransProps: audioTransProps)
        sendAudioPacket = sendFunc
        
        do {
#if os(iOS)
          try avAudSession.setActive(true, options: .notifyOthersOnDeactivation)
          try setIosAudioInterface(interface: inputInterface, session: avAudSession)
          try configureAvAudio(transProps: audioTransProps)
#elseif os(macOS)
          try setMacOsAudioInterfaces(input: inputInterface,
                                      output: outputInterface,
                                      avEngine: avEngine)
          try configureAudio(audioTransProps: audioTransProps, avEngine: avEngine)
#endif
          try avEngine.start()
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
            repeating: 0, count: 2 // avAudSession.inputNumberOfChannels
          )
        } catch {
          print(error)
        }
      },
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
        return nil
      }
    )
  }
}

#if os(iOS)
func initAvFoundation() {
  let avSession = AVAudioSession.sharedInstance()
  try? avSession.setCategory(
    .playAndRecord, mode: .measurement,
    options: [
      .allowAirPlay,
      .allowBluetoothA2DP,
      .duckOthers
    ]
  )
}

func configureAvAudio(transProps: AudioTransportDetails) throws {
  // Configure AVAudioSession
  let avSession = AVAudioSession.sharedInstance()
  let frameSizeMultiplier: UInt16 = transProps.codec == .opus64 ? 1 : 2
  let bufferDuration = TimeInterval(
    Float64(transProps.blockFactor.frameSize * frameSizeMultiplier) /
    ApiConsts.sampleRate48kHz
  )
  // Try to set session to 48kHz
  if avSession.sampleRate != Double(ApiConsts.sampleRate48kHz) {
    try avSession.setPreferredSampleRate(Double(ApiConsts.sampleRate48kHz))
  }
  try avSession.setPreferredIOBufferDuration(bufferDuration)
}

func iOsAudioInterfaces(session: AVAudioSession) -> [AudioInterface] {
  if let inputs = session.availableInputs {
    return inputs.map { AudioInterface.fromAvPortDesc(desc: $0) }
  }
  return []
}

func setIosAudioInterface(interface: AudioInterface.InterfaceSelection,
                          session: AVAudioSession) throws {
  switch interface {
    
  case .specific(let id):
    if let inputs = session.availableInputs,
       let found = inputs.first(where: { $0.portName == id }) {
      
      // Must be called with an active session
      try session.setPreferredInput(found)
    }
  case .systemDefault:
    try session.setPreferredInput(nil)
  }
}
#endif

#if os(macOS)

func configureAudio(audioTransProps: AudioTransportDetails,
                    avEngine: AVAudioEngine) throws {
  let frameSizeMultiplier: UInt16 = audioTransProps.codec == .opus64 ? 1 : 2
  var bufferFrameSize = UInt32(audioTransProps.blockFactor.frameSize * frameSizeMultiplier)
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
///
/// Retrieve a list of audio interfaces for use
///
func macOsAudioInterfaces() -> [AudioInterface] {
  var devices: [AudioInterface] = []
  
  do {
    // Figure out how many interfaces we have
    var aopa = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    let audioDeviceIds: [AudioDeviceID] = try arrayFromAOPA(&aopa,
                                                            forId: AudioObjectID(kAudioObjectSystemObject),
                                                            create: { [AudioDeviceID](repeating: 0, count: $0) })
    
    for deviceId in audioDeviceIds {
      // Enumerate
      var inputChannels = [UInt32]()
      var outputChannels = [UInt32]()
      var propertySize = UInt32()
      
      aopa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceName,
                                        mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
      // Get device Name
      let deviceName = try stringValueForAOPA(&aopa, forId: deviceId)
      // Manufacturer
      aopa.mSelector = kAudioDevicePropertyDeviceManufacturer
      let manufacturer = try stringValueForAOPA(&aopa, forId: deviceId)
      print(deviceName, manufacturer)
      
      // Capabilities
      aopa.mSelector = kAudioDevicePropertyStreams
      
      aopa.mScope = kAudioDevicePropertyScopeInput
      try throwIfError(AudioObjectGetPropertyDataSize(deviceId, &aopa, 0, nil, &propertySize))
      if propertySize > 0 {
        aopa.mSelector = kAudioDevicePropertyStreamConfiguration
        inputChannels = try channelArrayForAOPA(&aopa, forId: deviceId)
      }
      
      aopa.mScope = kAudioDevicePropertyScopeOutput
      try throwIfError(AudioObjectGetPropertyDataSize(deviceId, &aopa, 0, nil, &propertySize))
      if propertySize > 0 {
        aopa.mSelector = kAudioDevicePropertyStreamConfiguration
        outputChannels = try channelArrayForAOPA(&aopa, forId: deviceId)
      }
      var device = AudioInterface(id: deviceId, name: deviceName,
                                  inputChannelMap: inputChannels,
                                  outputChannelMap: outputChannels)
      device.notSupportedReason = try compatibilityCheck(device: device)
      devices.append(device)
    }
  }
  catch {
    print(error)
  }
  return devices
}


func setMacOsAudioInterfaces(input: AudioInterface.InterfaceSelection,
                             output: AudioInterface.InterfaceSelection,
                             avEngine: AVAudioEngine) throws {
//  if let inUnit = avEngine.inputNode.audioUnit {
//    switch input {
//    case .specific(let id):
//      try setAudioDevice(id: id, forAU: inUnit)
//     
//    case .systemDefault:
//      let systemId = try getSystemAudioDeviceId(forInput: true)
//      try setAudioDevice(id: systemId, forAU: inUnit)
//    }
//  }
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

/// Audio out source node for our engine.
/// This needs to be re-initialized if the output node changes its format
func audioSourceNode(
  dataSource: @escaping () -> NetworkBuffer,
  transportDetails: @escaping () -> AudioTransportDetails,
  updateBufferState: @escaping (BufferState) -> Void,
  opus: Opus.Custom?,
  opus64: Opus.Custom?,
  avEngine: AVAudioEngine
) -> AVAudioSourceNode {
  let outputFormat = avEngine.outputNode.outputFormat(forBus: 0)
  let frameRatio = outputFormat.sampleRate / opus48kFormat.sampleRate
  
  var converter: AVAudioConverter?
  if outputFormat != opus48kFormat {
    converter = AVAudioConverter(from: opus48kFormat, to: outputFormat)
  }
  
  return AVAudioSourceNode(
    format: opus48kFormat
  ) { isSilence, timestamp, frameCount, output in
    let audioTransProps = transportDetails()
    let netBuf = dataSource()
    
    var data: Data! = netBuf.read()
    updateBufferState(netBuf.state)
    
    if data == nil {
      data = Data()
      isSilence.pointee = true
    }
    
    var buffer: AVAudioPCMBuffer?
    if audioTransProps.codec == .opus64 {
      if let buf = try? opus64?.decode(
        data,
        compressedPacketSize: Int32(audioTransProps.opusPacketSize.rawValue),
        sampleMultiplier: Int32(audioTransProps.blockFactor.rawValue)
      ) {
        buffer = buf
      }
    } else {
      if let buf = try? opus?.decode(
        data,
        compressedPacketSize: Int32(audioTransProps.opusPacketSize.rawValue *
                                    UInt32(audioTransProps.blockFactor.rawValue)),
        sampleMultiplier: Int32(audioTransProps.blockFactor.rawValue)
      ) {
        buffer = buf
      }
    }
    
    if let buffer = buffer {
      let reSampleFrameCount = UInt32(Double(buffer.frameLength) * frameRatio)
      // Requires some form of conversion
      if frameCount == reSampleFrameCount,
         let audioConverter = converter,
         let convertedBuffer = AVAudioPCMBuffer(
          pcmFormat: opus48kFormat,
          frameCapacity: frameCount
         ) {
        var error: NSError? = nil
        audioConverter.convert(to: convertedBuffer, error: &error) { _, status in
          status.pointee = .haveData
          return buffer
        }
        output.assign(from: convertedBuffer.audioBufferList,
                      count: Int(convertedBuffer.audioBufferList.pointee.mNumberBuffers))
      } else {
        output.assign(from: buffer.audioBufferList,
                      count: Int(buffer.audioBufferList.pointee.mNumberBuffers))
      }
    } else {
      isSilence.pointee = true
    }
    return noErr
  }
}
