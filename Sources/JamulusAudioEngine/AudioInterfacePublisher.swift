
import AVFAudio
import Foundation

struct AudioInterfacePublisher {
  
  var interfaces: AsyncStream<[AudioInterface]>
#if os(iOS)
  var reasons: AsyncStream<AVAudioSession.RouteChangeReason>
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
  private static func reasonForChange(notification: Notification) -> AVAudioSession.RouteChangeReason? {
    if let userInfo = notification.userInfo,
       let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
       let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) {
      return reason
    }
    return nil
  }
  
  static var live: Self {
    
    let observerTask: Task<Void, Never>?
    
    var interfaceContinuation: AsyncStream<[AudioInterface]>.Continuation?
    let interfaces = AsyncStream<[AudioInterface]> { continuation in
      interfaceContinuation = continuation
    }
    var reasonsContinuation: AsyncStream<AVAudioSession.RouteChangeReason>.Continuation?
    let reasons = AsyncStream<AVAudioSession.RouteChangeReason> { continuation in
     reasonsContinuation = continuation
    }
    
    observerTask = Task { [interfaceContinuation, reasonsContinuation] in
      for await notification in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
        interfaceContinuation?.yield(
          AVAudioSession.sharedInstance()
            .currentRoute
            .inputs.map { AudioInterface.fromAvPortDesc(desc: $0) }
        )
        
        if let reason = reasonForChange(notification: notification) {
          reasonsContinuation?.yield(reason)
        }
      }
    }
    // TODO: Cancel the observerTask
    
    return .init(
      interfaces: interfaces,
      reasons: reasons
    )
  }
#elseif os(macOS)
  static var live: Self {
    
    var initialInterfaces = macOsAudioInterfaces()
    
    return .init(
      interfaces: AsyncStream { continuation in
        continuation.yield(macOsAudioInterfaces())
      }
    )
  }
#endif
}
