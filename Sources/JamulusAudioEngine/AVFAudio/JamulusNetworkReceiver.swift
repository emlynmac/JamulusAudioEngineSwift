
import AVFAudio
import Foundation
import JamulusProtocol
import Opus

final class JamulusNetworkReceiver {
  var transportProps: AudioTransportDetails
  var outputFormat: AVAudioFormat {
    didSet {
      setupConverter()
    }
  }
  private var converter: AVAudioConverter?
  private (set) var avSourceNode: AVAudioSourceNode!
  
  private func setupConverter() {
    if outputFormat != opus48kFormat {
      converter = AVAudioConverter(from: opus48kFormat, to: outputFormat)
    } else {
      converter = nil
    }
  }
  
  init(
    outputFormat: AVAudioFormat,
    transportDetails: AudioTransportDetails,
    opus: Opus.Custom,
    opus64: Opus.Custom,
    dataReceiver: @escaping () -> NetworkBuffer,
    updateBufferState: @escaping (BufferState) -> Void
  ) {
    self.outputFormat = outputFormat
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
          // Convert sample rate if needed
          if let converter = self.converter {
            do {
              if let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
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
                    return buffer
                  })
                
                if let err = error { throw JamulusError.avAudioError(err) }
                
                output.assign(
                  from: convertedBuffer.audioBufferList,
                  count: Int(convertedBuffer.audioBufferList.pointee.mNumberBuffers)
                )
              } else {
                throw JamulusError.audioConversionFailed
              }
            } catch {
              
            }
          } else {
            output.assign(
              from: buffer.audioBufferList,
              count: Int(buffer.audioBufferList.pointee.mNumberBuffers)
            )
          }
        } else {
          isSilence.pointee = true
        }
        return noErr
      }
  }
}
