
import AudioToolbox
import AVFoundation
import AVFAudio
import CoreAudio
import Foundation
import JamulusProtocol
import Opus


#if os(macOS)
extension JamulusAudioEngine {
  
  public static var coreAudio: Self {
        
    var audioConfig = JamulusCoreAudioConfig()
    let interfaceWatcher = AudioInterfaceProvider.avfAudio
    
    audioConfig.configureDefaultInInterface()
    audioConfig.configureDefaultOutInterface()
    
    return JamulusAudioEngine(
      recordingAllowed: {
        AVCaptureDevice.authorizationStatus(for: .audio) != .denied &&
        AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
      },
      requestRecordingPermission: {
        await AVCaptureDevice.requestAccess(for: .audio)
      },
      interfacesAvailable: interfaceWatcher.interfaces,
      setAudioInputInterface: { inInterface, inputMapping in
        audioConfig.inputChannelMapping = inputMapping
        audioConfig.activeInputDevice = inInterface
      },
      setAudioOutputInterface: { outInterface, outputMapping in
        audioConfig.outputChannelMapping = outputMapping
        audioConfig.activeOutputDevice = outInterface
      },
      inputVuLevels: audioConfig.vuLevelStream,
      bufferState: audioConfig.bufferStateStream,
      muteInput: { audioConfig.isInputMuted = $0 },
      start: { transportDetails, audioSender in
        audioConfig.audioTransProps = transportDetails
        
        do {
          guard let inId = audioConfig.activeInputDevice?.id,
                  audioConfig.audioInputProcId == nil else {
            throw JamulusError.noInputDevice
          }
          
          try configureAudioInterface(
            deviceId: inId,
            isInput: true,
            audioTransDetails: transportDetails
          )
          audioConfig.jitterBuffer.reset(
            blockSize: Int(transportDetails.opusPacketSize.rawValue)
          )
          try throwIfError(
            AudioDeviceCreateIOProcID(
              inId,
              ioCallbackIn,
              &audioConfig,
              &audioConfig.audioInputProcId
            )
          )
          audioConfig.audioSendFunc = { @Sendable packet in
            Task {
              await audioSender(packet)
            }
          }
          print("Created Input Callback")
          try throwIfError(
            AudioDeviceStart(inId, audioConfig.audioInputProcId)
          )
          print("Started Input Callback")
          
          guard let outId = audioConfig.activeOutputDevice?.id,
                audioConfig.audioOutputProcId == nil else {
            throw JamulusError.noOutputDevice
          }
          
          try configureAudioInterface(
            deviceId: outId, isInput: false,
            audioTransDetails: audioConfig.audioTransProps
          )
          try throwIfError(
            AudioDeviceCreateIOProcID(
              outId, ioCallbackOut,
              &audioConfig,
              &audioConfig.audioOutputProcId
            )
          )
          print("Created Output Callback")
          try throwIfError(AudioDeviceStart(outId, audioConfig.audioOutputProcId))
          
          print("Started Output Callback")
          
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
        audioConfig.inputLevels = [0,0]
        return nil
      },
      setReverbLevel: { level in print("REVERB NOT SUPPORTED YET!") },
      setReverbType: { reverbType in print("REVERB NOT SUPPORTED YET!") },
      handleAudioFromNetwork: audioConfig.jitterBuffer.write(_:),
      setNetworkBufferSize: { newSize in
        audioConfig.jitterBuffer.resizeTo(
          newCapacity: newSize,
          blockSize: Int(audioConfig.audioTransProps.opusPacketSize.rawValue)
        )
      },
      setTransportProperties: { transportDetails in
        let oldValues = audioConfig.audioTransProps
        audioConfig.audioTransProps = transportDetails
        
        do {
          if oldValues.frameSize != audioConfig.audioTransProps.frameSize {
            try configureAudio(config: audioConfig)
          }
        }
        catch {
          return JamulusError.avAudioError(error as NSError)
        }
        if oldValues.opusPacketSize != audioConfig.audioTransProps.opusPacketSize {
          audioConfig.jitterBuffer.reset(
            blockSize: Int(transportDetails.opusPacketSize.rawValue)
          )
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
  
  var outDeviceId = config.activeOutputDevice?.id
  if outDeviceId == nil {
    outDeviceId = try getSystemAudioDeviceId(forInput: false)
  }
//  try throwIfError(AudioDeviceStop(inDeviceId!, config.audioInputProcId))
  try configureAudioInterface(
    deviceId: inDeviceId!,
    isInput: true,
    audioTransDetails: config.audioTransProps
  )
  print("in interface configured")
//  try throwIfError(AudioDeviceStop(outDeviceId!, config.audioOutputProcId))
  try configureAudioInterface(
    deviceId: outDeviceId!,
    isInput: false,
    audioTransDetails: config.audioTransProps
  )
//  try throwIfError(AudioDeviceStart(inDeviceId!, config.audioInputProcId))
//  try throwIfError(AudioDeviceStart(outDeviceId!, config.audioOutputProcId))
  
  print("out interface configured")
}

private func configureAudioInterface(
  deviceId: AudioDeviceID?,
  isInput: Bool,
  audioTransDetails: AudioTransportDetails
) throws {
  guard let deviceId else {
    throw JamulusError.invalidAudioConfiguration
  }
  let _ = try setPreferredBufferSize(
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
                   timestamp: UnsafePointer<AudioTimeStamp>,
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
        compressedPacketSize: Int32(audioTransProps.opusPacketSize.rawValue * UInt32(audioTransProps.blockFactor.rawValue)),
        sampleMultiplier: Int32(audioTransProps.blockFactor.rawValue)
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
                  timestamp: UnsafePointer<AudioTimeStamp>,
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
    let bufferSize = inBuffersPtr.mBuffers.mDataByteSize
    
    var buffer = AVAudioPCMBuffer(
      pcmFormat: inputFormat,
      frameCapacity: bufferSize
    )
    
    // Map channels to buffer, as we must have 2 up / down to network

    
    // Audio in may be multiple discrete buffers or interleaved single buffer
    let audioBuf = inAudioBufPtr.unsafePointer[0]
    let channelCount = Int(audioBuf.mBuffers.mNumberChannels)
    let sampleCount = Int(audioBuf.mBuffers.mDataByteSize /
                         UInt32(MemoryLayout<UInt32>.size))
    let frameCount = sampleCount / channelCount
    
    // Processed frames
    var frames = 0
    let outPtr = buffer!.floatChannelData!.pointee
    
    if channelCount > 1 { // Have interleaved incoming data in the audio callback
      let data = inAudioBufPtr[UnsafeMutableAudioBufferListPointer.Index(0)]
        .mData?.assumingMemoryBound(to: Float32.self)
      for frameIdx in Swift.stride(from: 0, to: sampleCount, by: channelCount) {
        let leftOffset = frameIdx + channelMap[0]
        let rightOffset = frameIdx + channelMap[1]
        let leftSample = data![leftOffset]
        let rightSample = data![rightOffset]
        
        outPtr[frames] = leftSample
        outPtr[frames + 1] = rightSample
        frames += 2
      }
      
    } else {  // Should have multiple buffers, one for each channel
      let leftSource = inAudioBufPtr[UnsafeMutableAudioBufferListPointer.Index(channelMap[0])]
        .mData?.assumingMemoryBound(to: Float32.self)
      let rightSource = inAudioBufPtr[UnsafeMutableAudioBufferListPointer.Index(channelMap[1])]
        .mData?.assumingMemoryBound(to: Float32.self)
      
      for frame in 0..<Int(frameCount) {
        outPtr[frames] = leftSource![frame]
        outPtr[frames + 1] = rightSource![frame]
        frames += 2
      }
    }
    buffer?.frameLength = AVAudioFrameCount(frames)
    
    // Update the VU meter, but only at an appropriate rate.
    let sampleTimestamp = timestamp.pointee.mSampleTime

    if let start = audioConfig.sampleTimeStartOffset {
      if (Int(sampleTimestamp - start) % 8192) == 0 {
        if let vuData = buffer?.scaledPowerByChannel {
          audioConfig.inputLevels = vuData
        }
      }
    } else {
      audioConfig.sampleTimeStartOffset = sampleTimestamp
    }
    
    if audioConfig.isInputMuted {
      buffer?.silence()
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
