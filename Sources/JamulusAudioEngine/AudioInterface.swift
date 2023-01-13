
import AudioToolbox
import AVFAudio
import Foundation

///
/// Wraps an audio interface up for mapping channels and
/// selecting input / outputs 
///
public struct AudioInterface: Identifiable, Hashable {
  
#if os(macOS)
  public var id: AudioDeviceID
#else
  public var id: String
#endif
  
  public var audioUnit: AudioUnit?
  public var name: String
  public var inputChannelMap: [UInt32]
  public var inputChannelCount: Int { Int(inputChannelMap.reduce(0, +)) }
  public var outputChannelMap: [UInt32]
  public var outputChannelCount: Int { Int(outputChannelMap.reduce(0, +)) }
  public var notSupportedReason: String?
  public var isSystemInDefault: Bool = false
  public var isSystemOutDefault: Bool = false
  
  public var activeSampleRate: Double = 48_000
  public var inputInterleaved: Bool = false
  public var outputInterleaved: Bool = false
  
  public static func == (lhs: AudioInterface, rhs: AudioInterface) -> Bool {
    return lhs.name == rhs.name && lhs.id == rhs.id
  }
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(name)
    hasher.combine(id)
  }
  
#if os(iOS)
  static func fromAvPortDesc(desc: AVAudioSessionPortDescription, au: AudioUnit? = nil) -> Self {
    .init(
      id: desc.portName,
      audioUnit: au,
      name: desc.portName,
      inputChannelMap: desc.channels?.count == nil ? [2] : [UInt32(desc.channels!.count)],
      outputChannelMap: []
    )
  }
#endif
}


extension AudioInterface {
  static public var defaultOutInterface: AudioInterface {
#if os(macOS)
    return (try? defaultAudioDevice(forInput: false)) ??
    AudioInterface(
      id: 0,
      name: "System Default",
      inputChannelMap: [],
      outputChannelMap: [],
      isSystemOutDefault: true
    )

#elseif os(iOS)
    
#endif
  }
  
  static public var defaultInInterface: AudioInterface {
  
#if os(macOS)
    return (try? defaultAudioDevice(forInput: true)) ??
    AudioInterface(
      id: 0,
      name: "System Default",
      inputChannelMap: [],
      outputChannelMap: [],
      isSystemInDefault: true
    )
    
#elseif os(iOS)
    
#endif

  }
}

extension AudioInterface {
#if os(macOS)
  static public func preview(id: AudioDeviceID) -> Self {
    .init(
      id: id,
      name: "Audio IF",
      inputChannelMap: [0,1],
      outputChannelMap: [0,1]
    )
  }
#else
  static public func preview(id: Int) -> Self {
    .init(
      id: "\(id)",
      name: "Audio IF",
      inputChannelMap: [0,1],
      outputChannelMap: [0,1]
    )
  }
#endif
}
