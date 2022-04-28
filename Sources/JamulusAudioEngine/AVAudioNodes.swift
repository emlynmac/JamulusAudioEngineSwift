
import AVFAudio
import Foundation
import JamulusProtocol
import Opus


/// Audio out source node for our engine.
/// This needs to be re-initialized if the output node changes its format
///
func audioSourceNode(
  dataSource: @escaping () -> NetworkBuffer,
  transportDetails: @escaping () -> AudioTransportDetails,
  updateBufferState: @escaping (BufferState) -> Void,
  opus: Opus.Custom?,
  opus64: Opus.Custom?,
  avEngine: AVAudioEngine
) -> AVAudioSourceNode {
  
  let outputFormat = avEngine.outputNode.outputFormat(forBus: 0)
  let frameRatio = outputFormat.sampleRate / opus48kFormat.sampleRate
  
  var converter: AVAudioConverter?
  if outputFormat != opus48kFormat {
    converter = AVAudioConverter(from: opus48kFormat, to: outputFormat)
  }
  
  return AVAudioSourceNode(
    format: opus48kFormat
  ) { isSilence, timestamp, frameCount, output in
    let audioTransProps = transportDetails()
    let netBuf = dataSource()
    
    var data: Data! = netBuf.read()
    updateBufferState(netBuf.state)
    
    if data == nil {
      data = Data()
      isSilence.pointee = true
    }
    
    var buffer: AVAudioPCMBuffer?
    if audioTransProps.codec == .opus64 {
      if let buf = try? opus64?.decode(
        data,
        compressedPacketSize: Int32(audioTransProps.opusPacketSize.rawValue),
        sampleMultiplier: Int32(audioTransProps.blockFactor.rawValue)
      ) {
        buffer = buf
      }
    } else {
      if let buf = try? opus?.decode(
        data,
        compressedPacketSize: Int32(audioTransProps.opusPacketSize.rawValue *
                                    UInt32(audioTransProps.blockFactor.rawValue)),
        sampleMultiplier: Int32(audioTransProps.blockFactor.rawValue)
      ) {
        buffer = buf
      }
    }
    
    if let buffer = buffer {
      let reSampleFrameCount = UInt32(Double(buffer.frameLength) * frameRatio)
      // Requires some form of conversion
      if frameCount == reSampleFrameCount,
         let audioConverter = converter,
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
}


/// Audio input source node. Sends PCM buffers to opus and the network
///
func audioSinkNode(
  transportDetails: @escaping () -> AudioTransportDetails,
  sendAudioPacket: @escaping (Data) -> Void,
  avEngine: AVAudioEngine,
  isInputMuted: @escaping () -> Bool,
  vuLevels: @escaping ([Float]) -> Void
) -> AVAudioSinkNode {
  
  let kUpdateInterval: UInt8 = 64
  var counter: UInt8 = 0
  let inputFormat = avEngine.inputNode.inputFormat(forBus: 0)
  let converter = AVAudioConverter(from: inputFormat, to: opus48kFormat)
  
  return AVAudioSinkNode { timestamp, frameCount, pcmBuffers in
    counter = counter &+ 1
    let audioTransProps = transportDetails()
    
    guard let pcmBuffer = AVAudioPCMBuffer(
      pcmFormat: inputFormat,
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
      vuLevels(pcmBuffer.averageLevels)
      //        inputLevels = buf.decibelsByChannel.map{ $0.scaledPower(minDb: 30) }
    }
    
      if isInputMuted() { // Zero the buffer, as opus needs the packet
        let mutableBuffers = pcmBuffer.mutableAudioBufferList
        let bufListPtr = UnsafeMutableAudioBufferListPointer(&mutableBuffers.pointee)
        for buf in bufListPtr { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
      }
    
    // Encode and send the audio
    do {
      if pcmBuffer.format.isValidOpusPCMFormat &&
          pcmBuffer.format.channelCount == opus48kFormat.channelCount {
        JamulusAudioEngine.compressAndSendAudio(buffer: pcmBuffer,
                                                transportProps: audioTransProps,
                                                sendPacket: sendAudioPacket)
      } else {
        let frameRatio = opus48kFormat.sampleRate / inputFormat.sampleRate
        if let convertedBuffer = AVAudioPCMBuffer(
          pcmFormat: opus48kFormat,
          frameCapacity: UInt32(Double(pcmBuffer.frameLength) * frameRatio)
        ) {
          var error: NSError? = nil
          
          converter?.convert(
            to: convertedBuffer, error: &error,
            withInputFrom: { _, status in
              status.pointee = .haveData
              return pcmBuffer
            })
          
          JamulusAudioEngine.compressAndSendAudio(buffer: convertedBuffer,
                                                  transportProps: audioTransProps,
                                                  sendPacket: sendAudioPacket)
        } else {
          throw JamulusError.audioConversionFailed
        }
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
