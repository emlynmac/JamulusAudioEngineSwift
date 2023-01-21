
import AudioToolbox
import CoreAudio

#if os(macOS)
func stringValueForAOPA(_ aopa: inout AudioObjectPropertyAddress,
                        forId objId: AudioDeviceID) throws -> String {
  var stringSize: UInt32 = 0
  try throwIfError(AudioObjectGetPropertyDataSize(objId, &aopa, 0, nil, &stringSize))
  var cString = [CChar](repeating: 0, count: Int(stringSize))
  try throwIfError(AudioObjectGetPropertyData(objId, &aopa, 0, nil, &stringSize, &cString))
  
  return String(cString: cString)
}

func channelArrayForAOPA(_ aopa: inout AudioObjectPropertyAddress,
                         forId objId: AudioDeviceID) throws -> [UInt32] {
  let bufferList: AudioBufferList = try objectFromAOPA(&aopa, forId: objId)
  return [UInt32](repeating: bufferList.mBuffers.mNumberChannels,
                  count: Int(bufferList.mNumberBuffers))
}

func objectFromAOPA<T>(_ aopa: inout AudioObjectPropertyAddress,
                       forId objId: AudioDeviceID) throws -> T {
  var propSize: UInt32 = 0
  try throwIfError(AudioObjectGetPropertyDataSize(objId, &aopa, 0, nil, &propSize))
  let mem = UnsafeMutablePointer<T>.allocate(capacity: Int(propSize))
  defer {
    mem.deallocate()
  }
  try throwIfError(
    AudioObjectGetPropertyData(
      objId, &aopa, 0, nil,
      &propSize, mem
    )
  )
  return mem.pointee
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
  if err != noErr {
    var errBigEndian = err.bigEndian
    let error = Data(bytes: &errBigEndian, count: MemoryLayout<OSStatus>.size)
    print("CoreAudio error \(err) (\(String(data: error, encoding: .ascii)!))")
    
    throw AudioError.init(err: err)
  }
}

func compatibilityCheck(device: inout AudioInterface) throws -> String? {
  var incompatibleReason: String?
  
  // Check sample rate support, we want 48kHz
  var propertySize = UInt32(MemoryLayout<Float64>.size)
  var inputSampleRate = Float64()
  var aopa = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyNominalSampleRate,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  try throwIfError(
    AudioObjectGetPropertyData(
      device.id, &aopa, 0, nil, &propertySize, &inputSampleRate
    )
  )
  if inputSampleRate != sampleRate48kHz {
    inputSampleRate = sampleRate48kHz
    
    do {
      try throwIfError(
        AudioObjectSetPropertyData(
          device.id, &aopa, 0, nil, propertySize, &inputSampleRate
        )
      )
    } catch {
      incompatibleReason = "48kHz Sample Rate Not Supported!"
      device.activeSampleRate = inputSampleRate
      return incompatibleReason
    }
  }
  
  if device.inputChannelCount > 0 {   // Check input streams
    aopa.mSelector = kAudioDevicePropertyStreams
    aopa.mScope = kAudioObjectPropertyScopeInput
    let streamIds: [AudioStreamID] = try arrayFromAOPA(
      &aopa, forId: device.id,
      create: { [AudioStreamID](repeating: 0, count: $0) }
    )
    print("\(streamIds.count) input streams")
    guard let firstStreamId = streamIds.first else {
      return "Missing stream IDs for inputs"
    }
    let (isInterleaved, validationError) = try validateStream(
      id: firstStreamId, withAOPA: &aopa
    )
    device.inputInterleaved = isInterleaved
    
    guard validationError == nil else {
      return validationError
    }
  }
  
  if device.outputChannelCount > 0 {  // Check output streams
    aopa.mSelector = kAudioDevicePropertyStreams
    aopa.mScope = kAudioObjectPropertyScopeOutput
    let streamIds: [AudioStreamID] = try arrayFromAOPA(
      &aopa, forId: device.id,
      create: { [AudioStreamID](repeating: 0, count: $0) }
    )
    print("\(streamIds.count) output streams")
    guard let firstStreamId = streamIds.first else {
      return "Missing stream IDs for outputs"
    }
    let (isInterleaved, validationError) = try validateStream(
      id: firstStreamId, withAOPA: &aopa
    )
    device.outputInterleaved = isInterleaved
    guard validationError == nil else {
      return validationError
    }
  }
  return incompatibleReason
}

func validateStream(
  id: AudioStreamID,
  withAOPA aopa: inout AudioObjectPropertyAddress
) throws -> (Bool, String?) {
  
  aopa.mSelector = kAudioStreamPropertyVirtualFormat
  aopa.mScope = kAudioObjectPropertyScopeGlobal
  
  let streamFormat = try getStreamFormatFor(id: id, withAopa: &aopa)
  let isInterleaved =
  (streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
  var failReason: String?
  
  if streamFormat.mFormatID != kAudioFormatLinearPCM ||
      streamFormat.mFramesPerPacket != 1 ||
      streamFormat.mBitsPerChannel != 32 ||
      !(((streamFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0)) ||
      !(((streamFormat.mFormatFlags & kAudioFormatFlagIsPacked) != 0)) {
    failReason = "Audio Stream Format Incompatible"
  }
  return (isInterleaved, failReason)
}

func getStreamFormatFor(
  id: AudioStreamID,
  withAopa aopa: inout AudioObjectPropertyAddress
) throws -> AudioStreamBasicDescription {
  aopa.mSelector = kAudioStreamPropertyVirtualFormat
  aopa.mScope = kAudioObjectPropertyScopeGlobal
  return try objectFromAOPA(&aopa, forId: id)
}

func setBufferFrameSize(for au: AudioUnit?, to size: inout UInt32) -> OSStatus {
  guard let unit = au else { return noErr }
  
  return AudioUnitSetProperty(
    unit,
    kAudioDevicePropertyBufferFrameSize,
    kAudioUnitScope_Global,
    0,
    &size,
    UInt32(MemoryLayout.size(ofValue: size))
  )
}

func getSystemAudioDeviceId(forInput: Bool) throws -> AudioDeviceID {
  var aopa = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var deviceId: AudioObjectID = 0
  
  if forInput {
    aopa.mSelector = kAudioHardwarePropertyDefaultInputDevice
  }
  var propertySize: UInt32 = UInt32(MemoryLayout.size(ofValue: deviceId))
  try throwIfError(
    AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &aopa, 0, nil,
      &propertySize, &deviceId
    )
  )
  return deviceId
}

func setAudioDevice(id: AudioDeviceID, forAU audioUnit: AudioUnit) throws {
  var id = id
  
  try throwIfError(
    AudioUnitSetProperty(
    audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &id,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
  )
}

func setPreferredBufferSize(
  deviceId: AudioDeviceID, isInput: Bool, size: UInt32
) throws -> UInt32 {
  var aopa = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyBufferFrameSize,
    mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
  )
  var bufferSize: UInt32 = size
  let propertySize: UInt32 = UInt32(MemoryLayout.size(ofValue: bufferSize))
  
  try throwIfError(
    AudioObjectSetPropertyData(
      deviceId, &aopa, 0, nil,
      propertySize, &bufferSize
    )
  )
  // Passs back the value actually set (if throw is removed...)
  return bufferSize
}

#endif
