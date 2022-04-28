
import AVFAudio
import Foundation

extension AVAudioPCMBuffer {
  
  public var averageLevels: [Float] {
    let divisor: Float = !format.isInterleaved ? Float(frameLength) :
    Float(frameLength) / Float(format.channelCount)
    
    return processLevelsByChannel(outputModifier: { $0 })
      .map { $0 / divisor }
  }
  
  public var rmsPowerByChannel: [Float] {
    let divisor: Float = !format.isInterleaved ? Float(frameLength) :
    Float(frameLength) / Float(format.channelCount)
    
    return processLevelsByChannel(outputModifier: { $0 * $0 })
      .map { $0 / divisor }.map(sqrt)
  }
  
  public var decibelsByChannel: [Float] {
    rmsPowerByChannel.map { 20 * log10($0) }
  }
  
  func processLevelsByChannel(outputModifier: (Float) -> Float ) -> [Float] {
    let chanCount = Int(format.channelCount)
    guard chanCount > 0 else { return [] }
    var levels = [Float](repeating: 0, count: chanCount)
    guard let data = floatChannelData else { return levels }
    
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
