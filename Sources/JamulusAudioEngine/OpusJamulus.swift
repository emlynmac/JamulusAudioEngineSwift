
import JamulusProtocol
import Opus

public extension Opus.Custom {
  
  ///
  /// Sets up jamulus-specific parts of the custom opus implementation
  ///
  func configureForJamulus() throws {
    var error = Opus.Error.ok
    
    // Disable variable bit rates
    error = encoderCtl(request: OPUS_SET_VBR_REQUEST, value: 0)
    guard error == Opus.Error.ok else {
      throw JamulusError.opusError(error.rawValue)
    }

    // Typically not getting many packets dropped, so set to 5%
    error = encoderCtl(request: OPUS_SET_PACKET_LOSS_PERC_REQUEST, value: 5)
    error = encoderCtl(request: OPUS_SET_LSB_DEPTH_REQUEST, value: 16)

    guard error == Opus.Error.ok else {
      throw JamulusError.opusError(error.rawValue)
    }
  }
}
