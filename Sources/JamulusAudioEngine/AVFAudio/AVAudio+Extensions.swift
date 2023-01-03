
import AVFAudio
import Foundation

extension AVAudioPCMBuffer {
  
  public var averageLevels: [Float] {
    guard frameLength != 0 else {
      return format.isInterleaved ? [0] :
        .init(repeating: 0, count: Int(format.channelCount))
    }
    let divisor: Float = !format.isInterleaved ? Float(frameLength) :
    Float(frameLength) / Float(format.channelCount)
    
    return processLevelsByChannel(outputModifier: { $0 })
      .map { $0 / divisor }
  }
  
  public var rmsPowerByChannel: [Float] {
    guard frameLength != 0 else {
      return format.isInterleaved ? [0] :
        .init(repeating: 0, count: Int(format.channelCount))
    }
    
    
    let divisor: Float = !format.isInterleaved ? Float(frameLength) :
    Float(frameLength) / Float(format.channelCount)
    
    return processLevelsByChannel(outputModifier: { $0 * $0 })
      .map { $0 / divisor }
      .map(sqrt)
  }
  
  public var decibelsByChannel: [Float] {
    rmsPowerByChannel.map { 20 * log10($0) }
  }
  
  public var scaledPowerByChannel: [Float] {
    let minVal: Float = -70
    
    return decibelsByChannel.map {
      $0 < minVal ? 0.0 : $0 >= 1.0 ? 1.0 :
      (abs(minVal) - abs($0)) / abs(minVal)
    }
  }
  
  func processLevelsByChannel(outputModifier: (Float) -> Float ) -> [Float] {
    let chanCount = Int(format.channelCount)
    guard chanCount > 0 else { return [] }

    var levels = [Float](repeating: 0, count: chanCount)
    guard let data = floatChannelData else { return levels }
    
    // Process channel data points
    for chanIdx in 0..<chanCount {
      if format.isInterleaved {
        let chanData = data[0]
        for sampleIdx in Swift.stride(from: 0, to: Int(frameLength), by: stride) {
          let val = chanData[sampleIdx + chanIdx]
          levels[chanIdx] += abs(outputModifier(val))
        }
      } else {
        for sampleIdx in 0..<Int(frameLength) {
          for c in 0..<chanCount {
            levels[c] += abs(outputModifier(data[c][sampleIdx]))
          }
        }
      }
    }
    return levels
  }
  
  /// Zeroes out the buffers to make silence
  func silence() {
    let mutableBuffers = mutableAudioBufferList
    let bufListPtr = UnsafeMutableAudioBufferListPointer(&mutableBuffers.pointee)
    for buf in bufListPtr { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
  }
}
