
import Foundation

///
/// Provides a receive jitter buffer for audio packets in order to reduce drop outs.
/// Uses jamulus' audio packet sequence number
///
final class NetworkBuffer {
  
  public var state: BufferState = .empty {
    didSet {
      print("BufferState: \(state)")
    }
  }
  
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
    handleReset(blockSize: blockSize, capacity: newCapacity)
  }
  
  func reset(blockSize: Int) {
    handleReset(
      blockSize: blockSize,
      capacity: array.count
    )
  }
  
  private func handleReset(blockSize: Int, capacity: Int) {
    queue.sync {
      self.blockSize = blockSize
      array = [Data?](repeating: nil, count: capacity)
      readSeqNum = 0
      readIndex = 0
      writeIndex = 0
      state = .empty
    }
  }
  
  func read() -> Data? {
    queue.sync {
      let data = array[readIndex]
      // DEBUG_BUFFER
//      print("            R: \(readIndex) [\(String(array.map{$0 == nil ? "_" : "*"}))]")
      
      switch state {
      case .underrun, .empty:
        // No data, so need to buffer.
        // We can read once the buffer is full
        break

      case .normal:
        if data == nil {
          state = .underrun
        }

        array[readIndex] = nil
        readIndex += 1
        
        if readIndex == array.count { readIndex = 0 }
        // Update the expected sequence number
        readSeqNum = readSeqNum &+ 1
        
      default:
        break
      }
      
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
        
        switch state {
        case .empty:
          // First packet into the buffer after a reset
          readSeqNum = seqNum
          // DEBUG_BUFFER
//          print("First seqNum is \(seqNum) data is \(data.count) long")
          state = .underrun
          
        case .underrun:
          // Fill buffer until we're at capacity
          writeIndex = nextBufferIndex(index: writeIndex, stride: arrayCount)
          if seqNumDiff == arrayCount - 1 {
            state = .normal
          }
          
        default:
          if seqNumDiff < 0 {
//            print("seqNumDiff <= 0")
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
//            print("seqNumDiff >= arrayCount")
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
        }
        // DEBUG_BUFFER
//        print("W: \(writeIndex), diff: \(seqNumDiff)")
        array[writeIndex] = audioData
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
