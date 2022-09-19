
import AVFAudio
import Combine
import Foundation

struct AudioInterfacePublisher {
  
  var interfaces: AnyPublisher<[AudioInterface], Never>
#if os(iOS)
  var reasonPublisher: AnyPublisher<AVAudioSession.RouteChangeReason, Never>
#endif
}

#if os(iOS)
enum ChangeDetails {
  case oldDeviceUnvailable(AVAudioSessionPortDescription)
  case newDeviceAvailable(AVAudioSessionPortDescription)
}
#endif

extension AudioInterfacePublisher {
 
#if os(iOS)
  static var live: Self {
    let reasonsPub = PassthroughSubject<AVAudioSession.RouteChangeReason, Never>()
    
    return .init(
      interfaces: NotificationCenter
        .default
        .publisher(for: AVAudioSession.routeChangeNotification)
        .map { notification in

            if let userInfo = notification.userInfo,
               let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
               let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) {
              reasonsPub.send(reason)
            }
          
          return AVAudioSession.sharedInstance()
            .currentRoute
            .inputs.map { AudioInterface.fromAvPortDesc(desc: $0) }
        }
        .eraseToAnyPublisher(),
      reasonPublisher: reasonsPub.eraseToAnyPublisher()
    )
  }
#elseif os(macOS)
  static var live: Self {
    .init(
      interfaces: Just(
        macOsAudioInterfaces()
      )
        .eraseToAnyPublisher()
    )
  }
#endif
}
