
import Foundation
import JamulusProtocol

///
/// Provides a receive buffer for audio packets
/// in order to prevent audio drop outs.
///
final class NetworkBuffer {
  
  private enum State {
    case empty
    case full
    case normal
  }
  
  private let kGainBuffers = 2
  private let queue = DispatchQueue(label: "Receive Queue", qos: .userInteractive)
  
  private var array: [Data?]
  private var chunkSize: Int
  private var readIndex: Int = 0
  private var writeIndex: Int = 0
  private var expectedNextSeq: UInt8?
  private var validCount = 0
  private var state: State = .empty
  private var optimalBufferLevel: Int
  
  var count: Int { array.capacity }
  
  init(capacity: Int,
       blockSize: Int = Int(OpusCompressedSize.stereoNormalDouble.rawValue)) {
    array = [Data?](repeating: nil, count: capacity + kGainBuffers + 1)
    chunkSize = blockSize
    // Aim for mostly full at all times, as most likely to have drops
    optimalBufferLevel = capacity - kGainBuffers
  }
  
  /// Resize the array capacity to a new size
  func resizeTo(newCapacity: Int) {
    
  }
  
  func reset() {
    readIndex = 0
    writeIndex = 0
    expectedNextSeq = nil
    validCount = 0
    state = .empty
    print("Empty; Reset")
  }
  
  func write(_ data: Data) -> Void {
    guard !data.isEmpty else { return }
//    print("W \(validCount)")
    
    let lastByteIsSequence = data.count % chunkSize == 1
//    print("WRITE rIdx: \(readIndex), wIdx: \(writeIndex)")
   
    queue.sync {
      let arrayCount = array.count
      
      // For safe mode, network packets contain 2 frames.
      for startIdx in stride(from: 0, to: data.count, by: chunkSize) {
        guard startIdx + chunkSize < data.count else { break }
        
        if !lastByteIsSequence {
          // Simple case, just copy at write index and advance
          let packet = data[startIdx..<(startIdx+chunkSize)]
          if writeIndex == readIndex {
            // Move read index to keep a reasonable distance behind write
            readIndex = nextBufferIndex(index: readIndex,
                                        increment: -(arrayCount - kGainBuffers),
                                        stride: arrayCount)
          }
          array[writeIndex] = packet
          writeIndex = nextBufferIndex(index: writeIndex, stride: arrayCount)
          validCount = min(validCount+1, arrayCount)
        } else {
          let packet = data[startIdx..<(startIdx+chunkSize+1)]
          let seqNum = packet.last!
          
          if expectedNextSeq == nil { expectedNextSeq = seqNum }
          var diff: Int = Int(seqNum) - Int(expectedNextSeq!)
        
          if diff < -128 { diff += 256 }
          else if diff >= 128 { diff -= 256 }
          
          // Look at skew and handle appropriately
          if diff < 0 {
            // Out of order packet received, or server sample rate ahead
            print("Out of sequence by \(diff)")
            reset()
          } else if diff >= arrayCount {
            print("Dropped by \(diff)")
            // We had a drop-out of greater size than our buffer
            reset()
   
          } else { // 0 <= diff < arrayCount
            if diff != 0 {
              print("Missed packet- diff \(diff)")
            }
            // Just put the received packet into the array in the correct
            // location based on the sequence number
            writeIndex = nextBufferIndex(index: writeIndex,
                                         increment: diff,
                                         stride: arrayCount)
              
            // Wrap without causing a runtime error
            expectedNextSeq = expectedNextSeq! &+ 1
          }
          
          // Write data to the buffer
          if array[writeIndex] != nil {
            // Move read index to keep a reasonable distance behind write
            readIndex = nextBufferIndex(index: readIndex,
                                        increment: -(arrayCount - kGainBuffers),
                                        stride: arrayCount)
            validCount = arrayCount
          } else {
            validCount += 1
          }

          array[writeIndex] = packet.dropLast(1)
          writeIndex = nextBufferIndex(index: writeIndex, stride: arrayCount)
        }
      }
      // Update state
      if state == .empty && validCount >= arrayCount - kGainBuffers {
        state = .normal
        print("Normal")
      } else if state == .normal && validCount >= arrayCount {
        state = .full
        print("Full")
      }
    }
  }
  
  /// Helper to get the next index with wrapping
  private func nextBufferIndex(index: Int, increment: Int = 1, stride: Int) -> Int {
    var next = index + increment
    if next >= stride { next -= stride }
    if next < 0 { next += stride }
    return next
  }
  
  func read() -> Data? {
    queue.sync {
//      print("R \(validCount)")
//      print("READ rIdx: \(readIndex), wIdx: \(writeIndex)")
      
      // Make sure we have sufficiently buffered
      guard state != .empty else {
        return nil
      }
      // If read catches write, we don't read
      guard readIndex != writeIndex else {
        print ("HELP! Read caught Write")
        reset()
        return nil
      }
      
      defer {
        validCount -= 1
        if state != .empty && validCount < 1 {
          state = .empty
        }
        array[readIndex] = nil
        readIndex = nextBufferIndex(index: readIndex, stride: array.count)
      }
      return array[readIndex]
    }
  }
}

