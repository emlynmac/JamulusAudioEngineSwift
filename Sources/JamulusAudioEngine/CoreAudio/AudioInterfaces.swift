
import CoreAudio
import Foundation

#if os(macOS)

fileprivate func createAudioInterface(
  _ deviceId: AudioDeviceID
) throws -> AudioInterface {
  
  // Enumerate
  var inputChannels = [UInt32]()
  var outputChannels = [UInt32]()
  var propertySize = UInt32()
  
  var aopa = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceName,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  // Get device Name
  let deviceName = try stringValueForAOPA(&aopa, forId: deviceId)
  // Manufacturer
  aopa.mSelector = kAudioDevicePropertyDeviceManufacturer
  let manufacturer = try stringValueForAOPA(&aopa, forId: deviceId)
  print(deviceName, manufacturer)
  
  // Capabilities
  aopa.mSelector = kAudioDevicePropertyStreams
  
  aopa.mScope = kAudioDevicePropertyScopeInput
  try throwIfError(
    AudioObjectGetPropertyDataSize(deviceId, &aopa, 0, nil, &propertySize)
  )
  if propertySize > 0 {
    aopa.mSelector = kAudioDevicePropertyStreamConfiguration
    inputChannels = try channelArrayForAOPA(&aopa, forId: deviceId)
  }
  
  aopa.mScope = kAudioDevicePropertyScopeOutput
  try throwIfError(
    AudioObjectGetPropertyDataSize(deviceId, &aopa, 0, nil, &propertySize)
  )
  if propertySize > 0 {
    aopa.mSelector = kAudioDevicePropertyStreamConfiguration
    outputChannels = try channelArrayForAOPA(&aopa, forId: deviceId)
  }
  var device = AudioInterface(
    id: deviceId, name: deviceName,
    inputChannelMap: inputChannels,
    outputChannelMap: outputChannels
  )
  
  device.notSupportedReason = try compatibilityCheck(device: &device)
  return device
}

///
/// Retrieve a list of audio interfaces for use
///
func macOsAudioInterfaces() -> [AudioInterface] {
  var devices: [AudioInterface] = []
  
  do {
    let defaultInDeviceId = try defaultAudioId(forInput: true)
    let defaultOutDeviceId = try defaultAudioId(forInput: false)
    
    // Figure out how many interfaces we have
    var aopa = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let audioDeviceIds: [AudioDeviceID] = try arrayFromAOPA(
      &aopa,
      forId: AudioObjectID(kAudioObjectSystemObject),
      create: { [AudioDeviceID](repeating: 0, count: $0) }
    )
    
    for deviceId in audioDeviceIds {
      var device = try createAudioInterface(deviceId)
      if device.inputChannelCount > 0 {
        device.isSystemInDefault = deviceId == defaultInDeviceId
      }
      if device.outputChannelCount > 0 {
        device.isSystemOutDefault = deviceId == defaultOutDeviceId
      }
      devices.append(device)
    }
  }
  catch {
    print(error)
  }
  return devices
}

func defaultAudioId(forInput: Bool) throws -> AudioDeviceID {
  var deviceId: AudioDeviceID = 0
  var aopa = AudioObjectPropertyAddress(
    mSelector: forInput ? kAudioHardwarePropertyDefaultInputDevice :
      kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )

  var propertySize = UInt32(MemoryLayout.size(ofValue: deviceId))
  try throwIfError(
    AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &aopa, 0,
      nil,
      &propertySize,
      &deviceId)
  )
  return deviceId
}

func defaultAudioDevice(forInput: Bool) throws -> AudioInterface {
  let deviceId = try defaultAudioId(forInput: forInput)
  return try createAudioInterface(deviceId)
}

#endif
