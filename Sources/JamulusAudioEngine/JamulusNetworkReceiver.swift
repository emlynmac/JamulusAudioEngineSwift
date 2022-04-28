
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
  
  private var avSourceNode: AVAudioSourceNode!
  private var converter: AVAudioConverter?
  private var frameRatio: Double = 1
  
  private func setupConverter() {
    if outputFormat != opus48kFormat {
      converter = AVAudioConverter(from: opus48kFormat, to: outputFormat)
      frameRatio = outputFormat.sampleRate / opus48kFormat.sampleRate
    }
  }
  
  init(
    avEngine: AVAudioEngine,
    transportDetails: AudioTransportDetails,
    opus: Opus.Custom,
    opus64: Opus.Custom,
    dataReceiver: @escaping () -> NetworkBuffer,
    updateBufferState: @escaping (BufferState) -> Void
  ) {
    self.transportProps = transportDetails
    self.outputFormat = avEngine.outputNode.inputFormat(forBus: 0)
    
    avSourceNode = AVAudioSourceNode(
      format: opus48kFormat
    ) {  [weak self] isSilence, timestamp, frameCount, output in
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
        let reSampleFrameCount = UInt32(Double(buffer.frameLength) * self.frameRatio)
        // Requires some form of conversion
        if frameCount == reSampleFrameCount,
           let audioConverter = self.converter,
           let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: opus48kFormat,
            frameCapacity: frameCount
           ) {
          var error: NSError? = nil
          audioConverter.convert(to: convertedBuffer, error: &error) { _, status in
            status.pointee = .haveData
            return buffer
          }
          output.assign(from: convertedBuffer.audioBufferList,
                        count: Int(convertedBuffer.audioBufferList.pointee.mNumberBuffers))
        } else {
          output.assign(from: buffer.audioBufferList,
                        count: Int(buffer.audioBufferList.pointee.mNumberBuffers))
        }
      } else {
        isSilence.pointee = true
      }
      return noErr
    }
    
    // Attach to the engine
    avEngine.attach(avSourceNode)
    // Connect the network source to the output
    avEngine.connect(
      avSourceNode,
      to: avEngine.outputNode,
      fromBus: 0, toBus: 0,
      format: nil
    )
  }
}
