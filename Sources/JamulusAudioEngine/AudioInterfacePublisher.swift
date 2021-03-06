
import AVFAudio
import Combine
import Foundation

struct AudioInterfacePublisher {
  
  var interfaces: AnyPublisher<[AudioInterface], Never>
  var reasonPublisher: AnyPublisher<AVAudioSession.RouteChangeReason, Never>
}

enum ChangeDetails {
  case oldDeviceUnvailable(AVAudioSessionPortDescription)
  case newDeviceAvailable(AVAudioSessionPortDescription)
}


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
      interfaces: NotificationCenter
        .default
        .publisher(for: ???)
        .map { notification in
          
        }
        .eraseToAnyPublisher()
    )
  }
#endif
}
