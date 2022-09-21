import XCTest
import JamulusProtocol
@testable import JamulusAudioEngine

final class JamulusAudioEngineTests: XCTestCase {
  
  func test_core_audio_device_enumeration() async {
    
    let coreAudioImplementation = JamulusAudioEngine.coreAudio
    let availableInterfaces = await coreAudioImplementation
      .interfacesAvailable.first(where: { _ in true })
    
    XCTAssertNotNil(coreAudioImplementation)
    XCTAssert(availableInterfaces?.count ?? 0 > 0)
  }
  
  func test_core_audio_device_selection_input() async {
    let coreAudioImplementation = JamulusAudioEngine.coreAudio
    XCTAssertNotNil(coreAudioImplementation)
    
    let availableInterfaces = await coreAudioImplementation
      .interfacesAvailable.first(where: { _ in true })
    XCTAssert(availableInterfaces?.count ?? 0 > 0)
    
    let inputs = availableInterfaces?.filter({ $0.inputChannelCount > 0 }) ?? []
    let outputs = availableInterfaces?.filter({ $0.outputChannelCount > 0 }) ?? []
    
    XCTAssert(inputs.count > 0)
    XCTAssert(outputs.count > 0)
    
    coreAudioImplementation.setAudioInputInterface(inputs.first!, [0,1])
    coreAudioImplementation.setAudioOutputInterface(outputs.first!, [0,1])
  }
  
  func test_core_audio_device_selection_output() async {
    
  }
  
  func test_audio_send() async {
    let coreAudioImplementation = JamulusAudioEngine.coreAudio
    XCTAssertNotNil(coreAudioImplementation)
    
    let availableInterfaces = await coreAudioImplementation
      .interfacesAvailable.first(where: { _ in true })
    XCTAssert(availableInterfaces?.count ?? 0 > 0)
    
    let inputs = availableInterfaces?.filter({ $0.inputChannelCount > 0 }) ?? []
    let outputs = availableInterfaces?.filter({ $0.outputChannelCount > 0 }) ?? []
    
    XCTAssert(inputs.count > 0)
    XCTAssert(outputs.count > 0)
    coreAudioImplementation.setAudioInputInterface(inputs.first!, [0,1])
    coreAudioImplementation.setAudioOutputInterface(outputs.first!, [0,1])
    
    let packetSendExpectation = expectation(description: "Audio Packet Sent via callback")
    let transDetails = AudioTransportDetails.stereoNormal
    let audioSendFunc: (Data) -> Void = { data in
      XCTAssert(data.count == transDetails.opusPacketSize.rawValue)
      packetSendExpectation.fulfill()
    }
    
    let startError = coreAudioImplementation.start(transDetails, audioSendFunc)
    XCTAssertNil(startError)
    defer {
      _ = coreAudioImplementation.stop()
    }
    
    wait(for: [packetSendExpectation], timeout: 30)
  }
}
