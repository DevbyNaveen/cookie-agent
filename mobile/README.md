# Cookie on your phone

Your agents, their answers, and your yes or no, from your own Cookie runner.
Pairs by scanning the code in Cookie on your computer (Settings → Sharing →
Phone), over the runner's own HTTP API.

## Build

The platform folders are generated, not kept here:

```sh
cd mobile
flutter create --platforms=ios,android --org com.enkeon .
flutter pub get
flutter test
```

Then give the scanner its camera:

- iOS, `ios/Runner/Info.plist`: `NSCameraUsageDescription` = "Cookie scans the pairing code on your computer."
- Android, `android/app/src/main/AndroidManifest.xml`: `<uses-permission android:name="android.permission.CAMERA" />`

`flutter run` on a device. The runner must be reachable from the phone: an
https public address (Settings → Sharing → Public address) away from home;
iOS refuses plain http outside your own network.
