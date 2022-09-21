
import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import JamulusProtocol
import Opus

extension JamulusAudioEngine {
  
  public static var coreAudio: Self {
    
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
    
    var vuContinuation: AsyncStream<[Float]>.Continuation?
    let vuLevelStream = AsyncStream<[Float]> { continuation in
      vuContinuation = continuation
    }
    var inputLevels: [Float] = [0,0] {
      didSet {
        vuContinuation?.yield(inputLevels)
      }
    }
    
    
    var audioConfig = JamulusCoreAudioConfig()
    
    return JamulusAudioEngine(
      recordingAllowed: { true },
      requestRecordingPermission: { _ in },
      interfacesAvailable: AudioInterfacePublisher.live.interfaces,
      setAudioInputInterface: { selection, inputMapping in
        audioConfig.inputChannelMapping = inputMapping
        audioConfig.activeInputDevice = selection
      },
      setAudioOutputInterface: { selection, outputMapping in
        audioConfig.outputChannelMapping = outputMapping
        audioConfig.activeOutputDevice = selection
      },
      inputVuLevels: vuLevelStream,
      bufferState: bufferStateStream,
      muteInput: { shouldMute in
        
      },
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
          try configureAudio(audioTransProps: transportDetails)
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

private func configureAudio(audioTransProps: AudioTransportDetails) throws {
  
}

private func configureAudioInterface(
  deviceId: AudioDeviceID,
  isInput: Bool,
  audioTransDetails: AudioTransportDetails
) throws {
  var aopa = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyBufferFrameSize,
    mScope: isInput ? kAudioDevicePropertyScopeInput :
      kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
  )
  
  // Configure frame size buffer for the interface
  var frameSize = audioTransDetails.frameSize
  try throwIfError(
    AudioObjectSetPropertyData(
      deviceId, &aopa, 0,
      nil,
      UInt32(MemoryLayout<UInt32>.size),
      &frameSize
    )
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
  
  if let audioEngine = ref?.bindMemory(
    to: JamulusCoreAudioConfig.self,
    capacity: 1).pointee,
     id == audioEngine.activeOutputDevice?.id {
    print("º")
    // Get audio from jitter buffer
    // Decompress with Opus
    // Adjust sample rate if needed
    // Output to the audio card

  }
  
  return OSStatus.zero
}

///
/// Handle sending audio data from the audio interface to the ring buffer for the network to send
///
func ioCallbackIn(id: AudioObjectID,
                  _: UnsafePointer<AudioTimeStamp>,
                  buffersIn: UnsafePointer<AudioBufferList>,
                  _: UnsafePointer<AudioTimeStamp>,
                  _: UnsafeMutablePointer<AudioBufferList>,
                  _: UnsafePointer<AudioTimeStamp>,
                  ref: UnsafeMutableRawPointer?) -> OSStatus {
  
  if let audioConfig = ref?.bindMemory(
    to: JamulusCoreAudioConfig.self, capacity: 1).pointee,
     id == audioConfig.activeInputDevice?.id,
     let packetSender = audioConfig.audioSendFunc,
     let inputFormat = audioConfig.inputFormat,
     let channelMap = audioConfig.inputChannelMapping {
    
    let transportProps = audioConfig.audioTransProps
    print(".")
    
    let bufferSize = buffersIn.pointee.mBuffers.mDataByteSize
    let buffer = AVAudioPCMBuffer(
      pcmFormat: inputFormat,
      frameCapacity: bufferSize
    )
    
    // Map channels to buffer
    let inBufPtr = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: buffersIn)
    )
    
    var outChannel = 0
    for chan in channelMap {
      // Assign buffers to the AVAudioPCMBuffer
      memcpy(
        buffer!.floatChannelData![outChannel],
        &inBufPtr[chan],
        Int(bufferSize)
      )
      outChannel += 1
    }

    
    // Convert if needed
    if let converter = audioConfig.inputConverter {
//      converter.convert
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
  return OSStatus.zero
}

