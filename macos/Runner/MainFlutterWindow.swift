import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var audioEngine: MacSignalAudioEngine?
  private var audioChannel: FlutterMethodChannel?
  private var preferencesChannel: FlutterMethodChannel?
  private var closeObserver: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    title = "电波表授时"
    contentMinSize = NSSize(width: 360, height: 560)
    let channel = FlutterMethodChannel(name: "com.xiongjian.dianbo/signal", binaryMessenger: flutterViewController.engine.binaryMessenger)
    audioChannel = channel
    audioEngine = MacSignalAudioEngine { [weak self] status in self?.audioChannel?.invokeMethod("status", arguments: status) }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let engine = self?.audioEngine else { result(FlutterError(code: "AUDIO_CLOSED", message: "音频引擎已关闭", details: nil)); return }
      engine.handle(call, result: result)
    }
    let preferences = FlutterMethodChannel(name: "com.xiongjian.dianbo/preferences", binaryMessenger: flutterViewController.engine.binaryMessenger)
    preferencesChannel = preferences
    preferences.setMethodCallHandler { call, result in
      if call.method == "read" { result(UserDefaults.standard.string(forKey: "dianbo.preferences")) }
      else if call.method == "write", let raw = call.arguments as? String, raw.utf8.count <= 4096 {
        UserDefaults.standard.set(raw, forKey: "dianbo.preferences"); result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }
    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: self, queue: .main) { [weak self] _ in self?.audioEngine?.stop() }

    super.awakeFromNib()
  }

  deinit {
    if let closeObserver = closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
  }
}
