
import AVFAudio
import CoreAudio
import Foundation
import JamulusProtocol
import Opus

///
/// Contains the configuration parameters to be used by the CoreAudio callbacks
///
final class JamulusCoreAudioConfig {
  
  var activeInputDevice: AudioInterface? {
    willSet {
      configureInputConverter(newInterface: newValue)
    }
  }
  var inputChannelMapping: [Int]?
  var audioInputProcId: AudioDeviceIOProcID?
  var activeOutputDevice: AudioInterface? {
    willSet {
      configureOutputConverter(newInterface: newValue)
      if outputChannelMapping == nil {
        outputChannelMapping = [0, 1]
      }
    }
  }
  var outputChannelMapping: [Int]?
  var audioOutputProcId: AudioDeviceIOProcID?
  var audioTransProps: AudioTransportDetails = .stereoNormal {
    willSet {
      if newValue.codec != audioTransProps.codec {
        _ = opus?.encoderCtl(request: OPUS_RESET_STATE, value: 0)
        _ = opus64?.encoderCtl(request: OPUS_RESET_STATE, value: 0)
      }
    }
  }
  let jitterBuffer = NetworkBuffer(
    capacity: ApiConsts.defaultJitterBuffer,
    blockSize: Int(AudioTransportDetails.stereoNormal.opusPacketSize.rawValue)
  )
  var audioSendFunc: ((Data) -> Void)?
  
  var opus: Opus.Custom!
  var opus64: Opus.Custom!
  
  // Handle sample rate convertion / channel mapping
  var inputFormat: AVAudioFormat?
  var inputConverter: AVAudioConverter?
  var outputFormat: AVAudioFormat?
  var outputConverter: AVAudioConverter?
  
  init(
    activeInputDevice: AudioInterface? = nil,
    inputChannelMapping: [Int]? = nil,
    audioInputProcId: AudioDeviceIOProcID? = nil,
    activeOutputDevice: AudioInterface? = nil,
    outputChannelMapping: [Int]? = nil,
    audioOutputProcId: AudioDeviceIOProcID? = nil,
    audioTransProps: AudioTransportDetails = .stereoNormal,
    audioSendFunc: ((Data) -> Void)? = nil
  ) {
    self.activeInputDevice = activeInputDevice
    self.inputChannelMapping = inputChannelMapping
    self.audioInputProcId = audioInputProcId
    self.activeOutputDevice = activeOutputDevice
    self.outputChannelMapping = outputChannelMapping
    self.audioOutputProcId = audioOutputProcId
    self.audioTransProps = audioTransProps
    self.audioSendFunc = audioSendFunc
    
    self.opus = try? Opus.Custom(
      format: opus48kFormat,
      application: .audio,
      frameSize: UInt32(2 * ApiConsts.frameSamples64)
    )
    try? opus.configureForJamulus()
    self.opus64 = try? Opus.Custom(
      format: opus48kFormat,
      application: .audio,
      frameSize: UInt32(ApiConsts.frameSamples64)
    )
    try? opus64.configureForJamulus()
  }
  
  private func configureInputConverter(newInterface: AudioInterface?) {
    guard newInterface != activeInputDevice,
          let newInterface = newInterface else {
      return
    }
    
    if inputChannelMapping == nil {
      inputChannelMapping = newInterface.inputChannelCount > 1 ? [0, 1] : [0, 0]
    }
    
    let newInputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: newInterface.activeSampleRate,
      channels: AVAudioChannelCount(min(2, newInterface.inputChannelCount)),
      interleaved: newInterface.inputInterleaved
    )
    inputFormat = newInputFormat
    
    guard let audioFormat = newInputFormat,
          audioFormat != opus48kFormat else {
      inputConverter = nil
      return
    }
    
    let converter = AVAudioConverter(
      from: audioFormat,
      to: opus48kFormat
    )
    
    inputConverter = converter
  }
  
  private func configureOutputConverter(newInterface: AudioInterface?) {
    guard let newInterface = newInterface,
          newInterface != activeOutputDevice else {
      return
    }
    
    if outputChannelMapping == nil {
      outputChannelMapping = newInterface.outputChannelCount > 1 ? [0, 1] : [0, 0]
    }
    
    let newOutputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: newInterface.activeSampleRate,
      channels: AVAudioChannelCount(min(2, newInterface.outputChannelCount)),
      interleaved: newInterface.outputInterleaved
    )
    outputFormat = newOutputFormat
    
    guard let audioFormat = newOutputFormat,
          audioFormat != opus48kFormat else {
      outputConverter = nil
      return
    }
    
    let converter = AVAudioConverter(from: opus48kFormat, to: audioFormat)

    outputConverter = converter
  }
}