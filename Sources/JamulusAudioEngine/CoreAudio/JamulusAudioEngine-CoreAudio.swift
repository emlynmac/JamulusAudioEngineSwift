
import AudioToolbox
import CoreAudio
import Foundation
import JamulusProtocol
import Opus

extension JamulusAudioEngine {
  public static var coreAudio: Self {
    
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
    
    var vuContinuation: AsyncStream<[Float]>.Continuation?
    let vuLevelStream = AsyncStream<[Float]> { continuation in
      vuContinuation = continuation
    }
    var inputLevels: [Float] = [0,0] {
      didSet {
        vuContinuation?.yield(inputLevels)
      }
    }
    
    
    return JamulusAudioEngine(
      recordingAllowed: { true },
      requestRecordingPermission: { _ in },
      interfacesAvailable: AudioInterfacePublisher.live.interfaces,
      setAudioInputInterface: { selection, channels in
      },
      setAudioOutputInterface: { selection, channels in
        
      },
      inputVuLevels: vuLevelStream,
      bufferState: bufferStateStream,
      muteInput: { shouldMute in
        
      },
      start: { transportDetails, audioSender in
       
        return nil // JamulusError?
      },
      stop: {
        // TODO: Stop the audio
        return nil
      },
      setReverbLevel: { level in },
      setReverbType: { reverbType in },
      handleAudioFromNetwork: jitterBuffer.write(_:),
      setNetworkBufferSize: {
        jitterBuffer.resizeTo(
          newCapacity: $0,
          blockSize: Int(audioTransProps.opusPacketSize.rawValue)
        )
      },
      setTransportProperties: { transportDetails in
        do {
          try configureAudio(audioTransProps: transportDetails)
        }
        catch {
          return JamulusError.avAudioError(error as NSError)
        }
        
        audioTransProps = transportDetails
        return nil
      }
    )
  }
}

private func configureAudio(audioTransProps: AudioTransportDetails) throws {
  
}
