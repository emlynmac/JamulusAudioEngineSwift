import XCTest
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
    
  }
  
  func test_core_audio_device_selection_output() async {
    
  }
}
