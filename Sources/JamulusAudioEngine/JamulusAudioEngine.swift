
import AVFoundation
import Combine
import JamulusProtocol
import Opus

///
/// Audio handling for the app
///
public struct JamulusAudioEngine {
  
  /// Whether recording is permitted
  public var recordingAllowed: () -> Bool
  /// Request permission to record
  public var requestRecordingPermission: (@escaping (Bool) -> Void) -> Void
  
  /// Provide the list of available audio interfaces and their capabilities
  public var interfacePublisher: AnyPublisher<[AudioInterface], Never>
  
  /// Set the input interface to use
  /// First parameter is the interface to use, second is the channel mapping to use for L/R
  public var setAudioInputInterface: (AudioInterface.InterfaceSelection, [Int]?) -> Void
  /// Set the output interface to use
  /// First parameter is the interface to use, second is the channel mapping to use for L/R
  public var setAudioOutputInterface: (AudioInterface.InterfaceSelection, [Int]?) -> Void
  
  /// Provides the UI with a value to use on a VU meter
  public var inputLevelPublisher: AnyPublisher<[Float], Never>
  /// State of the network receive buffer
  public var bufferState: AnyPublisher<BufferState , Never>
  /// Mute the input
  public var muteInput: (Bool) -> Void
  /// Start the audio engine
  public var start: (AudioTransportDetails, @escaping ((Data) -> Void)) -> JamulusError?
  /// Stop the audio engine
  public var stop: () ->  JamulusError?
  
  public var setReverbLevel: (Float) -> Void
  public var setReverbType: (AVAudioUnitReverbPreset) -> Void
  
  /// Input for network Opus packet data
  public var handleAudioFromNetwork: (Data) -> Void
  /// Set the network receive jitter buffer size in terms of number of packets
  public var setNetworkBufferSize: (Int) -> Void
  /// Set the engine transport details
  public var setTransportProperties: (AudioTransportDetails) -> JamulusError?
}

///
/// Wrapper for CoreAudio errors
///
public struct AudioError: Error {
  public let code: OSStatus
  public init(err: OSStatus) { code = err }
}

public enum BufferState {
  case empty
  case normal
  case full
  case underrun
  case overruns
}

public extension JamulusAudioEngine {
  
  // Dummy for swiftUI previews
  static var preview: Self {
    .init(
      recordingAllowed: { true },
      requestRecordingPermission: { $0(true) },
      interfacePublisher: Just<[AudioInterface]>([]).eraseToAnyPublisher(),
      setAudioInputInterface: { _, _ in },
      setAudioOutputInterface: { _, _ in },
      inputLevelPublisher: Just([0.5,0.4]).eraseToAnyPublisher(),
      bufferState: Just(.normal).eraseToAnyPublisher(),
      muteInput: { _ in },
      start: { _,_  in nil},
      stop: { nil },
      setReverbLevel: { _ in },
      setReverbType: { _ in },
      handleAudioFromNetwork: { _ in },
      setNetworkBufferSize: { _ in },
      setTransportProperties: { details in nil })
  }
}

/// Jamulus uses 48k sample rate and the opus encoder needs an interleaved 2 channel format
let opus48kFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: sampleRate48kHz,
                                  channels: AVAudioChannelCount(2),
                                  interleaved: true)!
let sampleRate48kHz = Float64(48000)
