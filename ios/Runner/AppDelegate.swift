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

    // Configure Firebase
    FirebaseApp.configure()
    print("Firebase configured")

    // Set notification delegate (permission deferred to Flutter side)
    UNUserNotificationCenter.current().delegate = self

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

  // Handle notification tap
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                     didReceive response: UNNotificationResponse,
                                     withCompletionHandler completionHandler: @escaping () -> Void) {
    let userInfo = response.notification.request.content.userInfo
    print("Notification tapped: \(userInfo)")

    completionHandler()
  }
}
