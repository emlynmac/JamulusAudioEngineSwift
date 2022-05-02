
import AVFAudio
import Foundation
import JamulusProtocol
import Opus

final class JamulusNetworkSender {
  var transportProps: AudioTransportDetails {
    willSet {
      if newValue.codec != transportProps.codec {
         _ = opus.encoderCtl(request: OPUS_RESET_STATE, value: 0)
        _ = opus64.encoderCtl(request: OPUS_RESET_STATE, value: 0)
      }
    }
    didSet {
      setOpusBitrate()
    }
  }
  var inputFormat: AVAudioFormat {
    didSet {
      setupConverter()
    }
  }
  
  var inputMuted: Bool = true
  
  private (set) var avSinkNode: AVAudioSinkNode!
  private var converter: AVAudioConverter?
  
  private var opus: Opus.Custom
  private var opus64: Opus.Custom
  
  private func setupConverter() {
    if inputFormat != opus48kFormat {
      converter = AVAudioConverter(from: inputFormat, to: opus48kFormat)
    } else {
      converter = nil
    }
  }
  
  init(
    inputFormat: AVAudioFormat,
    transportDetails: AudioTransportDetails,
    opus: Opus.Custom,
    opus64: Opus.Custom,
    sendAudioPacket: @escaping (Data) -> Void,
    setVuLevels: @escaping ([Float]) -> Void
  ) {
    self.transportProps = transportDetails
    self.inputFormat = inputFormat
    self.opus = opus
    self.opus64 = opus64
    
    var counter: UInt8 = 0
    let moduluo: UInt8 = 64
    avSinkNode = AVAudioSinkNode { [weak self] timestamp, frameCount, pcmBuffers in
      guard let self = self else { return noErr }
      counter = counter &+ 1
      let audioTransProps = self.transportProps
      
      guard let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: self.inputFormat,
        bufferListNoCopy: pcmBuffers
      ) else {
        // Send dummy packet or the server thinks we died
        sendAudioPacket(
          Data(repeating: 0,
               count: Int(audioTransProps.opusPacketSize.rawValue))
        )
        print("COULD NOT CREATE AUDIO")
        return noErr
      }
      if counter % moduluo == 0 {
        setVuLevels(pcmBuffer.averageLevels)
      }
      
      // Silence the buffer after we allow the VU meter to show input
      if self.inputMuted {
        pcmBuffer.silence()
      }
      
      // Encode and send the audio
      do {
        if let converter = self.converter {
          if let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: opus48kFormat,
            frameCapacity: UInt32(audioTransProps.frameSize)
          ) {
            var error: NSError? = nil
            var consumedOnePacket = false
            converter.convert(
              to: convertedBuffer, error: &error,
              withInputFrom: { _, status in
                guard !consumedOnePacket else {
                  status.pointee = .noDataNow
                  return nil
                }
                status.pointee = .haveData
                consumedOnePacket = true
                return pcmBuffer
              })
            if let err = error { throw JamulusError.avAudioError(err) }
            
            self.compressAndSendAudio(buffer: convertedBuffer,
                                      transportProps: audioTransProps,
                                      sendPacket: sendAudioPacket)
          } else {
            throw JamulusError.audioConversionFailed
          }
        } else {  // format is compatible with Opus directly
          self.compressAndSendAudio(
            buffer: pcmBuffer,
            transportProps: audioTransProps,
            sendPacket: sendAudioPacket
          )
        }
      } catch {
        print(error)
        // Send dummy packet or the server thinks we died
        sendAudioPacket(
          Data(repeating: 0,
               count: Int(audioTransProps.opusPacketSize.rawValue))
        )
      }
      return noErr
    }
  }
  
  @discardableResult
  func setOpusBitrate() -> JamulusError? {
//    // Set opus bitrate
//    let bitrate = transportProps.bitRatePerSec()
//    var err = Opus.Error.ok
//    if transportProps.codec == .opus64 {
//      err = opus64.encoderCtl(request: OPUS_SET_BITRATE_REQUEST,
//                              value: bitrate)
//    } else {
//      err = opus.encoderCtl(request: OPUS_SET_BITRATE_REQUEST,
//                            value: bitrate)
//    }
//    guard err == Opus.Error.ok else {
//      return JamulusError.opusError(err.rawValue)
//    }
//    print("encoding bitrate set to: \(bitrate) bps")
    return nil
  }
  
  ///
  /// Sends an AVAudioPCMBuffer through the Opus compressor and calls
  /// the closure to send the compressed data over the network
  ///
  func compressAndSendAudio(buffer: AVAudioPCMBuffer,
                            transportProps: AudioTransportDetails,
                            sendPacket: ((Data) -> Void)?) {
    let packetSize = Int(transportProps.opusPacketSize.rawValue)
    
    var encodedData: Data?
    if transportProps.codec == .opus64 {
      encodedData = try? opus64.encode(
        buffer,
        compressedSize: packetSize)
    } else {
      encodedData = try? opus.encode(
        buffer,
        compressedSize: packetSize)
    }
    if let data = encodedData {
      sendPacket?(data)
    } else {
      // Send an empty packet
      print("Failed to encode audio packet")
      sendPacket?(Data(repeating: 0, count: packetSize))
    }
  }
}
