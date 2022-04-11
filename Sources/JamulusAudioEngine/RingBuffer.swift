//
//  RingBuffer.swift
//  Jam It Up
//
//  Created by Emlyn Bolton on 2022-03-20.
//
import Foundation

class RingBuffer<T> {
  private let queue = DispatchQueue(label: "Receive Queue", qos: .userInteractive)
  private var array: [T?]
  private var readIndex: UInt64 = 0
  private var writeIndex: UInt64 = 0
  
  var count: Int { Int(writeIndex - readIndex) }
  var isEmpty: Bool { count == 0 }
  
  var freeSpace: Int { array.count - count }
  var isFull: Bool { freeSpace == 0 }
  
  init(size: Int) {
    array = [T?](repeating: nil, count: size)
  }
  
  func read() -> T? {
    queue.sync {
      guard !isEmpty else { return nil }
      defer { array[wrapped: readIndex] = nil; readIndex += 1 }
      
      return array[wrapped: readIndex]
    }
  }
  
  func write(_ el: T) -> Bool {
    queue.sync {
      guard !isFull else { return false }
      defer { writeIndex += 1 }
      
      array[wrapped: writeIndex] = el
      return true
    }
  }
}

private extension Array {
  subscript (wrapped index: UInt64) -> Element {
    get { return self[Int(index) % Int(count)] }
    set { self[Int(index) % count] = newValue }
  }
}
