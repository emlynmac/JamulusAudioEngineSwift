
import AVFAudio
import Foundation

extension AVAudioPCMBuffer {
  
  public var averageLevels: [Float] {
    processLevelsByChannel(outputModifier: { $0 })
      .map { $0 / Float(frameLength) }
  }
  
  public var rmsPowerByChannel: [Float] {
    processLevelsByChannel(outputModifier: { $0 * $0 })
      .map { $0 / Float(frameLength) }.map(sqrt)
  }
  
  public var decibelsByChannel: [Float] {
    rmsPowerByChannel.map { 20 * log10($0) }
  }
  
  func processLevelsByChannel(outputModifier: (Float) -> Float ) -> [Float] {
    let chanCount = Int(format.channelCount)
    var levels = [Float](repeating: 0, count: chanCount)
    guard let data = floatChannelData else {
      return levels
    }
    
    for sampleIdx in Swift.stride(from: 0, to: Int(frameLength), by: stride) {
      for chanIdx in 0..<chanCount {
        var val: Float = 0
        if format.isInterleaved {
          val = data.pointee[sampleIdx + chanIdx]
        } else {
          val = data.pointee[(chanIdx*Int(frameLength)) + sampleIdx]
        }
        levels[chanIdx] += outputModifier(val)
      }
    }
    return levels
  }
}
