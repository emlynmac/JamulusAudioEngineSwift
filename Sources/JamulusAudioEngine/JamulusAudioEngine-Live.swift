import AVFoundation
import Combine
import Foundation
import Opus
import JamulusProtocol

extension JamulusAudioEngine {
  
  public static var live: Self {
#if !os(macOS)
    let avAudSession = AVAudioSession.sharedInstance()
#endif
    let vuPublisher = PassthroughSubject<Float, Never>()
    var inputLevel: Float = 0 {
      didSet {
        DispatchQueue.main.async {
          vuPublisher.send(inputLevel)
        }
      }
    }
    // Receive Jitter Buffer
    var jitterBuffer = RingBuffer<AVAudioPCMBuffer>(size: 20)
    var jitterBufferSize: Int { jitterBuffer.count }
    var audioTransProps: AudioTransportDetails = .stereoNormal
      
    var sendAudioPacket: ((Data) -> Void)?
    
    let avEngine = AVAudioEngine()
    let inputFormat = avEngine.inputNode.inputFormat(forBus: 0)
    let converter = AVAudioConverter(from: inputFormat, to: stereo48kFormat)
  
    
    /// Audio out source node for our engine. Audio is taken from the network audio ring buffer.
    let audioSource = AVAudioSourceNode(
      format: stereo48kFormat
    ) { isSilence, timestamp, frameCount, output in

      if let buffer = jitterBuffer.read() {
        output.assign(from: buffer.audioBufferList,
                      count: Int(buffer.audioBufferList.pointee.mNumberBuffers))
      } else {
        // Send silence for now
        isSilence.pointee = true
      }
      return noErr
    }
    avEngine.attach(audioSource)
    
    /// Audio input source node. Sends PCM buffers to opus and the network
    let audioSink = AVAudioSinkNode { timestamp, frameCount, pcmBuffers in

      if let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        bufferListNoCopy: pcmBuffers) {
        
        // Update the signal VU meter
        let rms = pcmBuffer.rmsPower
        // Convert to decibels
        let avgPower = 20 * log10(rms)
        inputLevel = avgPower.scaledPower()
    
        // Encode and send the audio
        do {
          if inputFormat.isValidOpusPCMFormat &&
              inputFormat.channelCount == stereo48kFormat.channelCount {
            compressAndSendAudio(buffer: pcmBuffer,
                      transportProps: audioTransProps,
                      sendPacket: sendAudioPacket)
          } else {
            if let convertedBuffer = AVAudioPCMBuffer(pcmFormat: stereo48kFormat,
                                                      frameCapacity: pcmBuffer.frameLength) {
              try converter?.convert(to: convertedBuffer, from: pcmBuffer)
              self.compressAndSendAudio(buffer: convertedBuffer,
                             transportProps: audioTransProps,
                             sendPacket: sendAudioPacket)
            } else {
              throw JamulusError.audioConversionFailed
            }
          }
        } catch {
          print(error)
        }
      }
          
      return noErr
    }
    avEngine.attach(audioSink)
    
    // Connect nodes
    // Connect the input to the sink
    avEngine.connect(avEngine.inputNode, to: audioSink, format: nil)
    // Connect the network source to the mixer
    avEngine.connect(audioSource, to: avEngine.mainMixerNode, format: nil)
    avEngine.mainMixerNode.volume = 1
    
    let audioEngine = JamulusAudioEngine(
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
      setAudioInterface: { chosen in
#if os(macOS)
        return setMacOsAudioInterface(interface: chosen)
#elseif os(iOS)
        return setIosAudioInterface(interface: chosen, session: avAudSession)
#endif
      },
      inputLevelPublisher: { vuPublisher.eraseToAnyPublisher() },
      start: { transportDetails, sendFunc in
        
        // Set opus bitrate
        var err = Opus.Error.ok.rawValue
        if transportDetails.codec == .opus64 {
          err = opus64.encoderCtl(request: OPUS_SET_BITRATE_REQUEST,
                                  value: audioTransProps.bitRatePerSec())
        } else {
          err = opus.encoderCtl(request: OPUS_SET_BITRATE_REQUEST,
                                value: audioTransProps.bitRatePerSec())
        }
        guard err == Opus.Error.ok.rawValue else {
          return JamulusError.opusError(err)
        }
        
        audioTransProps = transportDetails
        sendAudioPacket = sendFunc
        
        do {
          try configureAvAudio(transProps: audioTransProps)
#if !os(macOS)
          try avAudSession.setActive(true, options: .notifyOthersOnDeactivation)
#endif
          try avEngine.start()
        } catch {
          print(error)
          return nil
          //          return error
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
          inputLevel = 0
        } catch {
          print(error)
        }
      },
      handleAudioFromNetwork: { data in
        var data = data
        if audioTransProps.opusPacketSize.rawValue != data.count {
          let seq = data.removeLast()
          print(seq)
        }

        if audioTransProps.codec == .opus64 {
          if let decoded = try? opus64?.decode(data,
                                               sampleMultiplier: 1) {
            if !jitterBuffer.write(decoded) {
    //          print("Received Audio with no space to write to")
            }
          }
        } else {
          if let decoded = try? opus?.decode(data, sampleMultiplier: 1) {
            if !jitterBuffer.write(decoded) {
    //          print("Received Audio with no space to write to")
            }
          }
        }
      },
      setNetworkBufferSize: { size in
        // TODO: update jitter buffers
        return nil
      },
      setTransportProperties: { transportDetails in
        audioTransProps = transportDetails
        // TODO: apply changes
        return nil
      }
    )
    
    // Post construction config
    
    
    return audioEngine
  }
}

func configureAvAudio(transProps: AudioTransportDetails) throws {
  
#if os(iOS)
  // Configure AVAudioSession
  let avSession = AVAudioSession.sharedInstance()
  let frameSizeMultiplier: UInt16 = transProps.codec == .opus64 ? 1 : 2
  let bufferDuration = TimeInterval(
    Float64(transProps.blockFactor.frameSize * frameSizeMultiplier) /
    ApiConsts.sampleRate48kHz
  )
  try avSession.setCategory(.playAndRecord)
  try avSession.setPreferredSampleRate(Double(ApiConsts.sampleRate48kHz))
  try avSession.setPreferredIOBufferDuration(bufferDuration)
#endif
}

#if os(iOS)
func iOsAudioInterfaces(session: AVAudioSession) -> [AudioInterface] {
  if let inputs = session.availableInputs {
    return inputs.map(AudioInterface.fromAvPortDesc(desc:))
  }
  return []
}

func setIosAudioInterface(interface: AudioInterface,
                          session: AVAudioSession) -> Error? {
  if let inputs = session.availableInputs,
     let found = inputs.first(where: { $0.portName == interface.id }) {
    do {
      try session.setPreferredInput(found)
    } catch {
      return error
    }
  }
  return nil
}
#endif

#if os(macOS)
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


func setMacOsAudioInterface(interface: AudioInterface) -> Error? {
 
  return nil
}

#endif
