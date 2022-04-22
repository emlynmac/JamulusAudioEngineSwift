
import Foundation

///
/// Provides a receive jitter buffer for audio packets in order to reduce drop outs.
/// Uses jamulus' audio packet sequence number
///
final class NetworkBuffer {
  
  public var state: BufferState = .empty
  
  private let queue = DispatchQueue(label: "Receive Buffer Queue",
                                    qos: .userInteractive)
  private var array: [Data?]
  
  private var readSeqNum: UInt8 = 0
  private var blockSize: Int
  private var readIndex: Int = 0
  private var writeIndex: Int = 0
  
  init(capacity: Int, blockSize: Int) {
    array = [Data?](repeating: nil, count: capacity)
    self.blockSize = blockSize
  }
  
  func resizeTo(newCapacity: Int, blockSize: Int) {
    queue.sync {
      array = [Data?](repeating: nil, count: newCapacity)
      reset(blockSize: blockSize)
    }
  }
  
  func reset(blockSize: Int) {
    self.blockSize = blockSize
    readSeqNum = 0
    readIndex = 0
    writeIndex = 0
    state = .empty
  }
  
  func read() -> Data? {
    queue.sync {
      let data = array[readIndex]
      
      state = data == nil ? .underrun : .normal
      array[readIndex] = nil
      readIndex += 1
      
      if readIndex == array.count { readIndex = 0 }
      readSeqNum = readSeqNum &+ 1
      
      return data
    }
  }
  
  func write(_ data: Data) -> Void {
    guard !data.isEmpty else { return }
    
    queue.sync {
      let arrayCount = array.count
      let packetCount = data.count % blockSize
      let lastByteIsSequence = packetCount != 0
      let packetSize = lastByteIsSequence ? blockSize+1 : blockSize
      
      for startIdx in stride(from: 0, to: data.count, by: packetSize) {
        guard startIdx + blockSize < data.count else { break }
        
        let seqNum = data[startIdx + blockSize]
        let audioData = data[startIdx..<(startIdx+blockSize)]
        
        var seqNumDiff = Int(seqNum) - Int(readSeqNum)
        if seqNumDiff < -128 { seqNumDiff += 256 }
        else if seqNumDiff >= 128 { seqNumDiff -= 256 }
        
        if seqNumDiff < 0 {
          while seqNumDiff <= 0 {
            array[readIndex] = nil
            readSeqNum = readSeqNum &- 1
            readIndex = nextBufferIndex(
              index: readIndex, increment: -1, stride: arrayCount
            )
            seqNumDiff += 1
          }
          writeIndex = readIndex
        } else if seqNumDiff >= arrayCount {
          
          while seqNumDiff >= arrayCount-1 {
            array[readIndex] = nil
            readSeqNum = readSeqNum &+ 1
            readIndex = nextBufferIndex(index: readIndex, stride: arrayCount)
            seqNumDiff -= 1
          }
          
          writeIndex = nextBufferIndex(
            index: writeIndex, increment: array.count - 1, stride: arrayCount
          )
        } else {
          writeIndex = readIndex + seqNumDiff
          if writeIndex >= arrayCount { writeIndex -= arrayCount }
        }
        array[writeIndex] = audioData
        state = .normal
      }
    }
  }
  
  /// Helper to get array indices with wrapping
  private func nextBufferIndex(index: Int, increment: Int = 1,
                               stride: Int) -> Int {
    var next = index + increment
    while next >= stride { next -= stride }
    while next < 0 { next += stride }
    return next
  }
}
