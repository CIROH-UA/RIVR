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

  // MARK: - Badge

  /// Clear the app icon badge every time the app comes to the foreground.
  ///
  /// The server stamps `badge: 1` on every alert (notification-service.ts) and
  /// NOTHING ever set it back, so the red 1 stayed on the home screen forever
  /// once a single notification had arrived — whether or not the user had
  /// opened the app and read it. Reported from a device 2026-08-29.
  ///
  /// `fcm_service.dart` carried a comment reading "Clear iOS badge on launch"
  /// directly above a call to `setForegroundNotificationPresentationOptions`,
  /// which only decides how a notification is PRESENTED while the app is
  /// already open. It never touched the count. The comment described the fix
  /// this code is.
  ///
  /// Native rather than Dart on purpose: this must happen on EVERY foreground,
  /// including resumes where the Flutter engine is already running, and it must
  /// not depend on the Dart side being initialised or on a plugin's lifecycle
  /// callbacks firing in the right order.
  ///
  /// `setBadgeCount` is iOS 16+; the deployment target is 16.6, so there is no
  /// availability branch to get wrong.
  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    UNUserNotificationCenter.current().setBadgeCount(0) { error in
      if let error = error {
        print("Failed to clear app icon badge: \(error)")
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
