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
  public var availableInterfaces: () -> [AudioInterface]
  /// Set the input interface to use
  /// First parameter is the interface to use, second is the channel mapping to use for L/R
  public var setAudioInputInterface: (AudioInterface.InterfaceSelection, [Int]?) -> Void
  /// Set the output interface to use
  /// First parameter is the interface to use, second is the channel mapping to use for L/R
  public var setAudioOutputInterface: (AudioInterface.InterfaceSelection, [Int]?) -> Void
  
  /// Provides the UI with a value to use on a VU meter
  public var inputLevelPublisher: () -> AnyPublisher<[Float], Never>
  /// State of the network receive buffer
  public var bufferState: () -> AnyPublisher<BufferState , Never>
  /// Mute the input
  public var muteInput: (Bool) -> Void
  /// Start the audio engine
  public var start: (AudioTransportDetails, @escaping ((Data) -> Void)) -> JamulusError?
  /// Stop the audio engine
  public var stop: () -> Void
  
  /// Input for network Opus packet data
  public var handleAudioFromNetwork: (Data) -> Void
  /// Set the network receive jitter buffer size in terms of number of packets
  public var setNetworkBufferSize: (Int) -> Void
  /// Set the engine transport details
  public var setTransportProperties: (AudioTransportDetails) -> JamulusError?
  
  
  /// The opus instance supporting 128 frame encoding/decoding
  static var opus: Opus.Custom! = {
    let opus = try? Opus.Custom(
      format: opus48kFormat,
      application: .audio,
      frameSize: UInt32(2 * ApiConsts.frameSamples64))
    try? opus?.configureForJamulus()
    return opus
  }()
  
  /// The opus instance supporting 64 frame encoding/decoding
  static var opus64: Opus.Custom! = {
    let opus = try? Opus.Custom(
      format: opus48kFormat,
      application: .audio,
      frameSize: UInt32(ApiConsts.frameSamples64))
    try? opus?.configureForJamulus()
    return opus
  }()
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
      availableInterfaces: { [] },
      setAudioInputInterface: { _, _ in },
      setAudioOutputInterface: { _, _ in },
      inputLevelPublisher: { Just([0.5,0.4]).eraseToAnyPublisher() },
      bufferState: { Just(.normal).eraseToAnyPublisher() },
      muteInput: { _ in },
      start: { _,_  in nil},
      stop: { },
      handleAudioFromNetwork: { _ in },
      setNetworkBufferSize: { _ in },
      setTransportProperties: { details in nil })
  }
}

/// Jamulus uses 48k sample rate and the opus encoder needs an interleaved 2 channel format
let opus48kFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: 48000,
                                  channels: AVAudioChannelCount(2),
                                  interleaved: true)!
let sampleRate48kHz = Float64(48000)


extension JamulusAudioEngine {
  ///
  /// Sends an AVAudioPCMBuffer through the Opus compressor and calls
  /// the closure to send the compressed data over the network
  ///
  static func compressAndSendAudio(buffer: AVAudioPCMBuffer,
                                   transportProps: AudioTransportDetails,
                                   sendPacket: ((Data) -> Void)?) {
    let packetSize = Int(transportProps.opusPacketSize.rawValue)
    
    if transportProps.codec == .opus64 {
      if let encodedData = try? opus64.encode(
        buffer,
        compressedSize: packetSize) {
        sendPacket?(encodedData)
      }
    } else {
      guard let encodedData = try? opus.encode(
        buffer,
        compressedSize: packetSize) else {
        // Send an empty packet
        sendPacket?(Data(repeating: 0, count: packetSize))
        return
      }
      sendPacket?(encodedData)
    }
  }
}
