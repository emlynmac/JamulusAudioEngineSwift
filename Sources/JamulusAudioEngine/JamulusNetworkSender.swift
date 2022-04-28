
import AVFAudio
import Foundation
import JamulusProtocol

final class JamulusNetworkSender {
  var transportProps: AudioTransportDetails {
    didSet {
      setupConverter()
    }
  }
  var inputFormat: AVAudioFormat {
    didSet {
      setupConverter()
    }
  }
  var inputMuted: Bool = true
  
  private var avSinkNode: AVAudioSinkNode!
  private var converter: AVAudioConverter?
  private var frameRatio: Double = 1
  
  private func setupConverter() {
    if inputFormat != opus48kFormat {
      converter = AVAudioConverter(from: inputFormat, to: opus48kFormat)
      frameRatio = opus48kFormat.sampleRate / inputFormat.sampleRate
    }
  }
  
  init(
    avEngine: AVAudioEngine,
    transportDetails: AudioTransportDetails,
    sendAudioPacket: @escaping (Data) -> Void,
    vuLevelUpdater: @escaping ([Float]) -> Void
  ) {
    self.transportProps = transportDetails
    self.inputFormat = avEngine.inputNode.outputFormat(forBus: 0)
    
    let kUpdateInterval: UInt8 = 64
    var counter: UInt8 = 0
    
    avSinkNode = AVAudioSinkNode { [weak self] timestamp, frameCount, pcmBuffers in
      guard let self = self else { return noErr }
      
      let audioTransProps = self.transportProps
      counter = counter &+ 1
      
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
      
      if counter % kUpdateInterval == 0 {
        vuLevelUpdater(pcmBuffer.averageLevels)
//        vuLevelUpdater(pcmBuffer.decibelsByChannel
//          .map{ $0.scaledPower(minDb: 30) } )
      }
      
      if self.inputMuted {
        pcmBuffer.silence()
      }
      
      // Encode and send the audio
      do {
        if let converter = self.converter {
          if let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: opus48kFormat,
            frameCapacity: UInt32(Double(pcmBuffer.frameLength) * self.frameRatio)
          ) {
            var error: NSError? = nil
            converter.convert(
              to: convertedBuffer, error: &error,
              withInputFrom: { _, status in
                status.pointee = .haveData
                return pcmBuffer
              })
            if let err = error { throw JamulusError.avAudioError(err) }
            JamulusAudioEngine.compressAndSendAudio(buffer: convertedBuffer,
                                                    transportProps: audioTransProps,
                                                    sendPacket: sendAudioPacket)
          } else {
            throw JamulusError.audioConversionFailed
          }
        } else {  // format is compatible with Opus directly
          JamulusAudioEngine.compressAndSendAudio(
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
    
    avEngine.attach(avSinkNode)
    avEngine.connect(avEngine.inputNode,
                     to: avSinkNode,
                     fromBus: 0, toBus: 0,
                     format: nil)
  }
}
