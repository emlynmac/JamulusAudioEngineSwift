import AVFoundation
import Combine
import JamulusProtocol
import Opus

///
/// Audio handling for the app
///
public struct JamulusAudioEngine {
  
  public var recordingAllowed: () -> Bool
  public var requestRecordingPermission: (@escaping (Bool) -> Void) -> Void
  public var availableInterfaces: () -> [AudioInterface]
  public var setAudioInterface: (AudioInterface) -> Error?
  public var inputLevelPublisher: () -> AnyPublisher<Float, Never>
  public var muteInput: (Bool) -> Void
  public var start: (AudioTransportDetails, @escaping ((Data) -> Void)) -> JamulusError?
  public var stop: () -> Void
  
  public var handleAudioFromNetwork: (Data) -> Void
  public var setNetworkBufferSize: (Int) -> Error?
  public var setTransportProperties: (AudioTransportDetails) -> JamulusError?
  
  /// The opus instance supporting 128 frame encoding/decoding
  static var opus: Opus.Custom! = {
    let opus = try? Opus.Custom(
      format: stereo48kFormat,
      application: .audio,
      frameSize: UInt32(2 * ApiConsts.frameSamples64))
    try? opus?.configureForJamulus()
    return opus
  }()
  
  /// The opus instance supporting 64 frame encoding/decoding
  static var opus64: Opus.Custom! = {
    let opus = try? Opus.Custom(
      format: stereo48kFormat,
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


public extension JamulusAudioEngine {
  
  // Dummy for swiftUI previews
  static var preview: Self {
    .init(
      recordingAllowed: { true },
      requestRecordingPermission: { $0(true) },
      availableInterfaces: { [] },
      setAudioInterface: { _ in nil},
      inputLevelPublisher: { Just(0.5).eraseToAnyPublisher() },
      muteInput: { _ in },
      start: { _,_  in nil},
      stop: { },
      handleAudioFromNetwork: { _ in },
      setNetworkBufferSize: { _ in nil },
      setTransportProperties: { details in nil })
  }
}

/// The audio format needed for Opus to work properly for Jamulus
let stereo48kFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
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
