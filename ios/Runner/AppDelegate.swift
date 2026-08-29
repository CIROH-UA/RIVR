import UIKit
import Flutter
import MapboxMaps
import Firebase
import FirebaseMessaging
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    print("AppDelegate: Starting initialization...")

    // Firebase is initialized from Dart via Firebase.initializeApp().
    // Do NOT call FirebaseApp.configure() here — it conflicts with the
    // Dart-side init (different option sources cause duplicate-app error).

    // Set notification delegate (permission deferred to Flutter side)
    UNUserNotificationCenter.current().delegate = self

    // Ask iOS for an APNs token.
    //
    // Info.plist sets FirebaseAppDelegateProxyEnabled=false, so Firebase does
    // NOT swizzle the app delegate and will not do this for us. Nothing else
    // did either, so didRegisterForRemoteNotificationsWithDeviceToken below
    // never fired, Messaging.apnsToken was never set, getAPNSToken() returned
    // nil forever, and no FCM token was ever issued — see ADR 0008.
    //
    // This is safe to call before the user grants permission: it only asks the
    // system for a device token. iOS still shows nothing until the Dart side
    // calls requestPermission(), so it does not front-run the permission
    // prompt. Registering early means the token is ready by the time the user
    // opts in, rather than racing a 6-second poll.
    application.registerForRemoteNotifications()

    // See observeForegroundForBadgeClear: this must be an observer, because a
    // scene-based app never calls applicationDidBecomeActive on the delegate.
    observeForegroundForBadgeClear()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let tokenChannel = FlutterMethodChannel(
      name: "com.hydromap.rivr.mapbox/token",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )

    tokenChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "getMapboxToken" {
        if let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String {
          result(token)
        } else {
          result(FlutterError(code: "NO_TOKEN", message: "No MapBox token found", details: nil))
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    })
  }

  // MARK: - Push Notification Handlers

  override func application(_ application: UIApplication,
                           didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    print("APNS token registered successfully")
    Messaging.messaging().apnsToken = deviceToken
  }

  override func application(_ application: UIApplication,
                           didFailToRegisterForRemoteNotificationsWithError error: Error) {
    print("Failed to register for remote notifications: \(error)")
  }

  // Handle notification when app is in foreground
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                     willPresent notification: UNNotification,
                                     withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    let userInfo = notification.request.content.userInfo
    print("Foreground notification received: \(userInfo)")

    // Show notification even when app is in foreground
    completionHandler([[.alert, .sound, .badge]])
  }

  // MARK: - Badge

  /// Clear the app icon badge every time the app comes to the foreground.
  ///
  /// The server stamps `badge: 1` on every alert (notification-service.ts) and
  /// NOTHING ever set it back, so the red 1 stayed on the home screen forever
  /// once a single notification had arrived — whether or not the user had
  /// opened the app and read it. Reported from a device 2026-08-29.
  ///
  /// **This is a NotificationCenter observer, not an
  /// `applicationDidBecomeActive` override, and that distinction is the whole
  /// bug.** Info.plist declares a `UIApplicationSceneManifest` (scene delegate
  /// `FlutterSceneDelegate`, added by the UIScene work merged 2026-08-24). In a
  /// scene-based app UIKit calls `sceneDidBecomeActive(_:)` on the SCENE
  /// delegate and never calls `applicationDidBecomeActive(_:)` on the app
  /// delegate at all. The first attempt at this fix was that override: it
  /// compiled, it read correctly, its test passed, and it never once executed.
  /// The badge did not move on device.
  ///
  /// The scene delegate is Flutter's own class, so subclassing it would mean
  /// changing the manifest and taking on the UIScene migration that was only
  /// just stabilised. An observer needs neither, and fires under both
  /// lifecycles — `UIScene.didActivateNotification` for the scene app we are,
  /// and `UIApplication.didBecomeActiveNotification` if the manifest is ever
  /// removed. Clearing twice is harmless; clearing never is the bug.
  private func observeForegroundForBadgeClear() {
    let center = NotificationCenter.default
    center.addObserver(self,
                       selector: #selector(clearBadge),
                       name: UIScene.didActivateNotification,
                       object: nil)
    center.addObserver(self,
                       selector: #selector(clearBadge),
                       name: UIApplication.didBecomeActiveNotification,
                       object: nil)
  }

  /// `setBadgeCount` is iOS 16+; the deployment target is 16.6, so there is no
  /// availability branch to get wrong.
  @objc private func clearBadge() {
    UNUserNotificationCenter.current().setBadgeCount(0) { error in
      if let error = error {
        print("Failed to clear app icon badge: \(error)")
      } else {
        print("App icon badge cleared")
      }
    }
  }

  // Handle notification tap.
  //
  // MUST forward to super. Info.plist sets FirebaseAppDelegateProxyEnabled=false,
  // so Firebase does not swizzle this method and depends on the delegate chain
  // to reach it. This override previously logged the payload and called
  // completionHandler() itself, which swallowed the tap: FlutterFire never saw
  // it, onMessageOpenedApp never fired, and notificationRoute — correct, and
  // covered by tests — was simply never invoked. Tapping a notification put the
  // user back on whatever screen they last had open.
  //
  // Do not call completionHandler() here as well; super owns it, and calling it
  // twice is undefined behaviour.
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                     didReceive response: UNNotificationResponse,
                                     withCompletionHandler completionHandler: @escaping () -> Void) {
    print("Notification tapped: \(response.notification.request.content.userInfo)")
    super.userNotificationCenter(center,
                                 didReceive: response,
                                 withCompletionHandler: completionHandler)
  }
}
