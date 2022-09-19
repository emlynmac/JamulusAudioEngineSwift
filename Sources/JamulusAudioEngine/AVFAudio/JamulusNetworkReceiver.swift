
import AVFAudio
import Foundation
import JamulusProtocol
import Opus

final class JamulusNetworkReceiver {
  var transportProps: AudioTransportDetails
  
  private (set) var avSourceNode: AVAudioSourceNode!

  init(
    transportDetails: AudioTransportDetails,
    opus: Opus.Custom,
    opus64: Opus.Custom,
    dataReceiver: @escaping () -> NetworkBuffer,
    updateBufferState: @escaping (BufferState) -> Void
  ) {
    self.transportProps = transportDetails
    
    avSourceNode = AVAudioSourceNode(
      format: opus48kFormat) { [weak self] isSilence, timestamp, frameCount, output in
      guard let self = self else {
        isSilence.pointee = true
        return noErr
      }
      
      let audioTransProps = self.transportProps
      let netBuf = dataReceiver()
      
      var data: Data! = netBuf.read()
      updateBufferState(netBuf.state)
      
      if data == nil {
        data = Data()
        isSilence.pointee = true
        return noErr
      }
      
      var buffer: AVAudioPCMBuffer?
      if audioTransProps.codec == .opus64 {
        if let buf = try? opus64.decode(
          data,
          compressedPacketSize: Int32(audioTransProps.opusPacketSize.rawValue),
          sampleMultiplier: Int32(audioTransProps.blockFactor.rawValue)
        ) {
          buffer = buf
        }
      } else {
        if let buf = try? opus.decode(
          data,
          compressedPacketSize: Int32(audioTransProps.opusPacketSize.rawValue *
                                      UInt32(audioTransProps.blockFactor.rawValue)),
          sampleMultiplier: Int32(audioTransProps.blockFactor.rawValue)
        ) {
          buffer = buf
        }
      }
      if let buffer = buffer {
          output.assign(from: buffer.audioBufferList,
                        count: Int(buffer.audioBufferList.pointee.mNumberBuffers))
      } else {
        isSilence.pointee = true
      }
      return noErr
    }
  }
}
