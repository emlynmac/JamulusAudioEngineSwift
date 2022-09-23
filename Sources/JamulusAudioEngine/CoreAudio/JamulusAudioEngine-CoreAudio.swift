
import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import JamulusProtocol
import Opus

#if os(macOS)
extension JamulusAudioEngine {
  
  public static var coreAudio: Self {
        
    var audioConfig = JamulusCoreAudioConfig()
    let interfaceWatcher = AudioInterfaceProvider.live
    
    var availableInterfaces: [AudioInterface] = []
    
    let availableInterfaceStream = AsyncStream<[AudioInterface]> { c in
      Task {
        for await ifs in interfaceWatcher.interfaces {
          availableInterfaces = ifs
          c.yield(ifs)
        }
      }
    }
    
    return JamulusAudioEngine(
      recordingAllowed: { true },
      requestRecordingPermission: { true },
      interfacesAvailable: availableInterfaceStream,
      setAudioInputInterface: { selection, inputMapping in
        audioConfig.inputChannelMapping = inputMapping
        switch selection {
        case .systemDefault:
          audioConfig.activeInputDevice = nil
        case .specific(let interface):
          audioConfig.activeInputDevice = interface
        }
      },
      setAudioOutputInterface: { selection, outputMapping in
        audioConfig.outputChannelMapping = outputMapping
        switch selection {
        case .systemDefault:
          audioConfig.activeOutputDevice = nil
        case .specific(let interface):
          audioConfig.activeOutputDevice = interface
        }
      },
      inputVuLevels: audioConfig.vuLevelStream,
      bufferState: audioConfig.bufferStateStream,
      muteInput: { audioConfig.isInputMuted = $0 },
      start: { transportDetails, audioSender in
        do {
          if let inId = audioConfig.activeInputDevice?.id,
             audioConfig.audioInputProcId == nil {
            try configureAudioInterface(
              deviceId: inId, isInput: true,
              audioTransDetails: transportDetails
            )
            try throwIfError(AudioDeviceCreateIOProcID(inId,
                                                       ioCallbackIn,
                                                       &audioConfig,
                                                       &audioConfig.audioInputProcId)
            )
            audioConfig.audioSendFunc = audioSender
            print("Created Input Callback")
            try throwIfError(AudioDeviceStart(inId, audioConfig.audioInputProcId))
            print("Started Input Callback")
          }
          
          if let outId = audioConfig.activeOutputDevice?.id, audioConfig.audioOutputProcId == nil  {
            try configureAudioInterface(
              deviceId: outId, isInput: false,
              audioTransDetails: audioConfig.audioTransProps
            )
            try throwIfError(AudioDeviceCreateIOProcID(outId, ioCallbackOut,
                                                       &audioConfig,
                                                       &audioConfig.audioOutputProcId)
            )
            print("Created Output Callback")
            try throwIfError(AudioDeviceStart(outId, audioConfig.audioOutputProcId))
            
            print("Started Output Callback")
          }
        } catch {
          return JamulusError.avAudioError(error as NSError)
        }
        return nil
      },
      stop: {
        if let inId = audioConfig.activeInputDevice?.id,
           let procId = audioConfig.audioInputProcId {
          do {
            try throwIfError(AudioDeviceStop(inId, procId))
            try throwIfError(AudioDeviceDestroyIOProcID(inId, procId))
            audioConfig.audioInputProcId = nil
            audioConfig.audioSendFunc = nil
          } catch {
            print("Failed to stop audio input: \(error.localizedDescription)")
            return JamulusError.avAudioError(error as NSError)
          }
        }
        
        if let outId = audioConfig.activeOutputDevice?.id,
           let procId = audioConfig.audioOutputProcId {
          
          do {
            try throwIfError(AudioDeviceStop(outId, procId))
            try throwIfError(AudioDeviceDestroyIOProcID(outId, procId))
            audioConfig.audioOutputProcId = nil
          } catch {
            print("Failed to stop audio output: \(error.localizedDescription)")
            return JamulusError.avAudioError(error as NSError)
          }
        }
        return nil
      },
      setReverbLevel: { level in },
      setReverbType: { reverbType in },
      handleAudioFromNetwork: audioConfig.jitterBuffer.write(_:),
      setNetworkBufferSize: {
        audioConfig.jitterBuffer.resizeTo(
          newCapacity: $0,
          blockSize: Int(audioConfig.audioTransProps.opusPacketSize.rawValue)
        )
      },
      setTransportProperties: { transportDetails in
        do {
          try configureAudio(config: audioConfig)
        }
        catch {
          return JamulusError.avAudioError(error as NSError)
        }
        
        audioConfig.audioTransProps = transportDetails
        return nil
      }
    )
  }
}

private func configureAudio(config: JamulusCoreAudioConfig) throws {
  var inDeviceId = config.activeInputDevice?.id
  if inDeviceId == nil {
   inDeviceId = try getSystemAudioDeviceId(forInput: true)
  }
  
  try configureAudioInterface(
    deviceId: inDeviceId!, isInput: true,
    audioTransDetails: config.audioTransProps
  )
}

private func configureAudioInterface(
  deviceId: AudioDeviceID,
  isInput: Bool,
  audioTransDetails: AudioTransportDetails
) throws {
  
  let bufferSize = try setPreferredBufferSize(
    deviceId: deviceId,
    isInput: isInput,
    size: UInt32(audioTransDetails.frameSize)
  )
}

///
/// Handle sending audio data from the network buffer to the audio out to play locally
///
func ioCallbackOut(id: AudioObjectID,
                   _: UnsafePointer<AudioTimeStamp>,
                   _: UnsafePointer<AudioBufferList>,
                   _: UnsafePointer<AudioTimeStamp>,
                   buffersOut: UnsafeMutablePointer<AudioBufferList>,
                   _: UnsafePointer<AudioTimeStamp>,
                   ref: UnsafeMutableRawPointer?) -> OSStatus {
  
  if let audioConfig = ref?.bindMemory(
    to: JamulusCoreAudioConfig.self,
    capacity: 1).pointee,
     id == audioConfig.activeOutputDevice?.id,
     let outputFormat = audioConfig.outputFormat,
     let channelMap = audioConfig.outputChannelMapping {
    
    // TODO: Verify valid channelMap
    let audioTransProps = audioConfig.audioTransProps
    
    guard let opusAudio = audioConfig.jitterBuffer.read() else {
      // Buffer underrun,
      // TODO: report underrun?
      print("_")
      return .zero
    }

    var buffer: AVAudioPCMBuffer?
    
    // Decompress with Opus
    if audioTransProps.codec == .opus64 {
      if let buf = try? audioConfig.opus64.decode(
        opusAudio,
        compressedPacketSize: Int32(audioTransProps.opusPacketSize.rawValue)
      ) {
        buffer = buf
      }
    } else {
      if let buf = try? audioConfig.opus.decode(
        opusAudio,
        compressedPacketSize: Int32(audioTransProps.opusPacketSize.rawValue) * 2
      ) {
        buffer = buf
      }
    }
    
    // Convert to output hardware requirements
    if let converter = audioConfig.outputConverter,
       let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: UInt32(audioTransProps.frameSize)
       ) {
      var error: NSError? = nil
      var consumedOnePacket = false
      converter.convert(to: convertedBuffer, error: &error) { _, status in
        guard !consumedOnePacket else {
          status.pointee = .noDataNow
          return nil
        }
        status.pointee = .haveData
        consumedOnePacket = true
        return buffer
      }
      buffer = convertedBuffer
    }
  
    // Map channels and output to the buffer
    if let buffer = buffer {
      let outAudioBufPtr = UnsafeMutableAudioBufferListPointer(buffersOut)
      let sourceData = buffer.floatChannelData!.pointee
      
      let leftBuf = outputFormat.isInterleaved ?
      outAudioBufPtr[0].mData!.assumingMemoryBound(to: Float32.self) :
      outAudioBufPtr[channelMap[0]].mData!.assumingMemoryBound(to: Float32.self)
      let rightBuf = outputFormat.isInterleaved ?
      outAudioBufPtr[0].mData!.assumingMemoryBound(to: Float32.self) :
      outAudioBufPtr[channelMap[1]].mData!.assumingMemoryBound(to: Float32.self)
      
      for sampleIdx in Swift.stride(
        from: 0, to: Int(buffer.frameLength*opus48kFormat.channelCount),
        by: Int(opus48kFormat.channelCount)
      ) {
        let leftSample = sourceData[sampleIdx]
        let rightSample = sourceData[sampleIdx+1]
        
        if outputFormat.isInterleaved {
          leftBuf[sampleIdx+channelMap[0]] = leftSample
          rightBuf[sampleIdx+channelMap[1]] = rightSample
        } else {
          leftBuf[sampleIdx] = leftSample
          rightBuf[sampleIdx] = rightSample
        }
      }
    }
  }
  
  return .zero
}

///
/// Handle sending audio data from the audio interface, to Opus and then over the network
///
func ioCallbackIn(id: AudioObjectID,
                  _: UnsafePointer<AudioTimeStamp>,
                  buffersIn: UnsafePointer<AudioBufferList>,
                  _: UnsafePointer<AudioTimeStamp>,
                  _: UnsafeMutablePointer<AudioBufferList>,
                  _: UnsafePointer<AudioTimeStamp>,
                  ref: UnsafeMutableRawPointer?) -> OSStatus {
  
  if let audioConfig = ref?.bindMemory(
    to: JamulusCoreAudioConfig.self, capacity: 1
  ).pointee,
     id == audioConfig.activeInputDevice?.id,
     let packetSender = audioConfig.audioSendFunc,
     let inputFormat = audioConfig.inputFormat,
     let channelMap = audioConfig.inputChannelMapping {
    
    let transportProps = audioConfig.audioTransProps
    
    let inAudioBufPtr = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: buffersIn)
    )
    let inBuffersPtr = buffersIn.pointee
    let inBuffersCount = inBuffersPtr.mNumberBuffers
    let bufferSize = inBuffersPtr.mBuffers.mDataByteSize
    
    var buffer = AVAudioPCMBuffer(
      pcmFormat: inputFormat,
      frameCapacity: bufferSize
    )
    
    // Map channels to buffer, as we must have 2 up / down to network
    var outChannel = 0
    
    // Audio in may be multiple discrete buffers or interleaved single buffer
    for bufferIdx in 0..<inBuffersCount {
      
      let audioBuf = inAudioBufPtr.unsafePointer[Int(bufferIdx)]
      let channelCount = Int(audioBuf.mBuffers.mNumberChannels)
      let frameCount = Int(audioBuf.mBuffers.mDataByteSize /
                            UInt32(MemoryLayout<UInt32>.size))
      
      let data = inAudioBufPtr[UnsafeMutableAudioBufferListPointer.Index(bufferIdx)]
        .mData?.assumingMemoryBound(to: Float32.self)
      
      while outChannel < 2 {
        if inputFormat.isInterleaved {
          let outPtr = buffer!.floatChannelData!.pointee
          
          for sampleIdx in Swift.stride(from: 0, to: frameCount, by: channelCount) {
            let leftSample = data![sampleIdx + channelMap[outChannel]]
            let rightSample = data![sampleIdx + channelMap[outChannel+1]]
            
            outPtr[sampleIdx] = leftSample
            outPtr[sampleIdx + 1] = rightSample
          }
          outChannel = 2
        } else {
          let outPtr = buffer!.floatChannelData![outChannel]
          for frame in 0..<Int(frameCount) {
            outPtr[frame] = data![frame]
          }
          outChannel += 1
        }
      }
      buffer?.frameLength = AVAudioFrameCount(frameCount*2)
    }
    
    // Convert if needed
    if let converter = audioConfig.inputConverter,
       let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: opus48kFormat,
        frameCapacity: UInt32(transportProps.frameSize)
      ) {
          var error: NSError? = nil
          var consumedOnePacket = false
          converter.convert(to: convertedBuffer, error: &error) { _, status in
            guard !consumedOnePacket else {
              status.pointee = .noDataNow
              return nil
            }
            status.pointee = .haveData
            consumedOnePacket = true
            return buffer
      }
      buffer = convertedBuffer
    }
    
    // Grab buffers in format for Opus
    if let avBuffer = AVAudioPCMBuffer(pcmFormat: opus48kFormat,
                                       bufferListNoCopy: buffer!.audioBufferList) {
      // Compress with Opus
      let packetSize = Int(transportProps.opusPacketSize.rawValue)
      var encodedData: Data?
      if transportProps.codec == .opus64 {
        encodedData = try? audioConfig.opus64.encode(avBuffer, compressedSize: packetSize)
      } else {
        encodedData = try? audioConfig.opus.encode(avBuffer, compressedSize: packetSize)
      }
      
      // Send over the network
      if let data = encodedData {
        packetSender(data)
      }
    } else {
      // Send an empty packet
      print("ERROR: Opus Compression Failed!")
      packetSender(
        Data(
          repeating: 0,
          count: Int(transportProps.opusPacketSize.rawValue)
        )
      )
      // TODO: Return error?
    }
  }
  return .zero
}

#endif
