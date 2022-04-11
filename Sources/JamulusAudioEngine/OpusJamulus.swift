//
//  OpusJamulus.swift
//  Jam It Up
//
//  Created by Emlyn Bolton on 2022-03-21.
//

import JamulusProtocol
import Opus

public extension Opus.Custom {
  
  ///
  /// Sets up jamulus-specific parts of the custom opus implementation
  ///
  func configureForJamulus() throws {
    var error = Opus.Error.ok.rawValue
    
    // Disable variable bit rates
    error = encoderCtl(request: OPUS_SET_VBR_REQUEST, value: 0)
    guard error == Opus.Error.ok.rawValue else {
      throw JamulusError.opusError(error)
    }
 
    switch frameSize {
    case 64:
      // Adjust PLC behaviour for better drop out handling
      error = encoderCtl(request: OPUS_SET_PACKET_LOSS_PERC_REQUEST, value: 35)
      guard error == Opus.Error.ok.rawValue else {
        throw JamulusError.opusError(error)
      }
      
    case 128:
      // Set complexity for 128 sample frame size
      error = encoderCtl(request: OPUS_SET_COMPLEXITY_REQUEST, value: 1)
      guard error == Opus.Error.ok.rawValue else {
        throw JamulusError.opusError(error)
      }
      
    default:
      break
    }
  }
}
