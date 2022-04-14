import AudioToolbox
import CoreAudio

#if os(macOS)
func stringValueForAOPA(_ aopa: inout AudioObjectPropertyAddress,
                        forId objId: AudioDeviceID) throws -> String {
  var stringSize: UInt32 = 0
  try throwIfError(AudioObjectGetPropertyDataSize(objId, &aopa, 0, nil, &stringSize))
  var cString = [CChar](repeating: 0, count: Int(stringSize))
  try throwIfError( AudioObjectGetPropertyData(objId, &aopa, 0, nil, &stringSize, &cString))
  
  return String(cString: cString)
}

func channelArrayForAOPA(_ aopa: inout AudioObjectPropertyAddress,
                         forId objId: AudioDeviceID) throws -> [UInt32] {
  var bufferList = AudioBufferList()
  try objectFromAOPA(&aopa, forId: objId, object: &bufferList)
  let channelCount = bufferList.mBuffers.mNumberChannels
  return [UInt32](repeating: channelCount, count: Int(bufferList.mNumberBuffers))
}

func objectFromAOPA<T>(_ aopa: inout AudioObjectPropertyAddress,
                       forId objId: AudioDeviceID,
                       object: inout T) throws {
  var propSize: UInt32 = UInt32(MemoryLayout<T>.size)
#if DEBUG
  let expectedSize = propSize
  try throwIfError(AudioObjectGetPropertyDataSize(objId, &aopa, 0, nil, &propSize))
  if expectedSize != propSize {
    print("Mismatch on size of property expectations: expected is \(expectedSize), actual is \(propSize)")
  }
//  assert(expectedSize >= propSize, "Property size from CoreAudio differs from passed value - check the request")
#endif
  try throwIfError(AudioObjectGetPropertyData(objId, &aopa, 0, nil,
                                              &propSize, &object))
}

func arrayFromAOPA<T>(_ aopa: inout AudioObjectPropertyAddress,
                      forId objId: AudioDeviceID,
                      create: ((Int) -> [T])) throws -> [T]  {
  var propSize: UInt32 = 0
  try throwIfError(AudioObjectGetPropertyDataSize(objId, &aopa, 0, nil, &propSize))
  let numOfElements = Int(propSize) / MemoryLayout<T>.size
  
  var array = create(numOfElements)
  try throwIfError(AudioObjectGetPropertyData(objId, &aopa, 0, nil, &propSize, &array))
  
  return array
}

func throwIfError(_ err: OSStatus) throws {
  if err != kAudioCodecNoError {
    var errBigEndian = err.bigEndian
    let error = Data(bytes: &errBigEndian, count: MemoryLayout<OSStatus>.size)
    print("CoreAudio error: \(String(data: error, encoding: .ascii)!)")
    
    throw AudioError.init(err: err)
  }
}

func compatibilityCheck(device: AudioInterface) throws -> String? {
  var incompatibleReason: String?
  
  // Check sample rate support, we want 48kHz
  var propertySize = UInt32(MemoryLayout<Float64>.size)
  var inputSampleRate = Float64()
  var aopa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                        mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
  try throwIfError(AudioObjectGetPropertyData(device.id, &aopa, 0, nil, &propertySize, &inputSampleRate))
  if inputSampleRate != sampleRate48kHz {
    inputSampleRate = sampleRate48kHz
    
    do {
      try throwIfError(AudioObjectSetPropertyData(device.id, &aopa, 0, nil, propertySize, &inputSampleRate))
    } catch {
      incompatibleReason = "48kHz Sample Rate Not Supported!"
      return incompatibleReason
    }
  }
  
  if device.inputChannelCount > 0 {   // Check input streams
    aopa.mSelector = kAudioDevicePropertyStreams
    aopa.mScope = kAudioObjectPropertyScopeInput
    let streamIds: [AudioStreamID] = try arrayFromAOPA(&aopa, forId: device.id,
                                                       create: { [AudioStreamID](repeating: 0, count: $0) })
    guard let firstStreamId = streamIds.first else { return "Missing stream IDs for inputs" }
    if let validationError = try validateStream(id: firstStreamId, withAOPA: &aopa) {
      return validationError
    }
  }
  
  if device.outputChannelCount > 0 {  // Check output streams
    aopa.mSelector = kAudioDevicePropertyStreams
    aopa.mScope = kAudioObjectPropertyScopeOutput
    let streamIds: [AudioStreamID] = try arrayFromAOPA(&aopa, forId: device.id,
                                                       create: { [AudioStreamID](repeating: 0, count: $0) })
    guard let firstStreamId = streamIds.first else { return "Missing stream IDs for outputs" }
    if let validationError = try validateStream(id: firstStreamId, withAOPA: &aopa) {
      return validationError
    }
  }
  return incompatibleReason
}

func validateStream(id: AudioStreamID,
                    withAOPA aopa: inout AudioObjectPropertyAddress) throws -> String? {
  
  aopa.mSelector = kAudioStreamPropertyVirtualFormat
  aopa.mScope = kAudioObjectPropertyScopeGlobal
  
  var streamFormat = AudioStreamBasicDescription()
  try getStreamFormatFor(id: id, withAopa: &aopa, streamDescription: &streamFormat)
  if streamFormat.mFormatID != kAudioFormatLinearPCM ||
      streamFormat.mFramesPerPacket != 1 ||
      streamFormat.mBitsPerChannel != 32 ||
      !(((streamFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0)) ||
      !(((streamFormat.mFormatFlags & kAudioFormatFlagIsPacked) != 0)) {
    return "Audio Stream Format Incompatible"
  }
  return nil
}

func getStreamFormatFor(id: AudioStreamID,
                        withAopa aopa: inout AudioObjectPropertyAddress,
                        streamDescription: inout AudioStreamBasicDescription) throws {
  aopa.mSelector = kAudioStreamPropertyVirtualFormat
  aopa.mScope = kAudioObjectPropertyScopeGlobal
  try objectFromAOPA(&aopa, forId: id, object: &streamDescription)
}

#endif
