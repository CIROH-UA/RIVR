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
