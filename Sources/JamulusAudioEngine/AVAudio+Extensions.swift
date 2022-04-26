
import AVFAudio
import Foundation

extension AVAudioPCMBuffer {
  public var rmsPower: Float {
    if let data = floatChannelData {
      let dataPtr = data.pointee
      let dataArray = Swift.stride(from: 0,
                             to: Int(frameLength),
                             by: stride)
        .map { dataPtr[$0] }
      
      // Normalized Signal Power
      return sqrt(dataArray
        .map { $0 * $0 }
        .reduce(0, +)
      ) / Float(frameLength)
    }
    return 0
  }
}
