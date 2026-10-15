import AVFoundation
import Cocoa
import FlutterMacOS

/** 由 Flutter 提供、按 UTC 整分钟排列的不可变包络数据。 */
private struct SignalPlan {
  let baseMicros: Int64
  let levels: [UInt8]
}

/**
 * 实时音频线程独占相位和增益，控制参数及统计通过短临界区交换。
 * 渲染回调仅尝试加锁，遇到主线程更新则沿用上一快照，不阻塞音频线程。
 */
private final class MacSignalSession: @unchecked Sendable {
  private let controlLock = NSLock()
  private let statsLock = NSLock()
  private var plan: SignalPlan
  private var running = true
  private var volume: Double
  private var cachedPlan: SignalPlan
  private var cachedRunning = true
  private var cachedVolume: Double
  private var phase = 0.0
  private var gain = 0.0
  private var locked = false
  private var rendered: Int64 = 0
  private var failure: String?
  let frequency: Double
  let frameSeconds: Int64
  let continuous: Bool
  let anchorUtcMicros: Int64
  let anchorMonoNanos: UInt64
  let firstFullFrameMicros: Int64
  let singleEndMicros: Int64
  var latency = 0.0
  private let createdNanos = DispatchTime.now().uptimeNanoseconds

  init(plan: SignalPlan, frequency: Double, frameSeconds: Int64, continuous: Bool,
       utcMicros: Int64, monoNanos: UInt64, volume: Double) {
    self.plan = plan
    cachedPlan = plan
    self.frequency = frequency
    self.frameSeconds = frameSeconds
    self.continuous = continuous
    anchorUtcMicros = utcMicros
    anchorMonoNanos = monoNanos
    self.volume = volume
    cachedVolume = volume
    let now = utcMicros + Int64(DispatchTime.now().uptimeNanoseconds - monoNanos) / 1000
    let frame = frameSeconds * 1_000_000
    firstFullFrameMicros = (now + frame - 1) / frame * frame
    singleEndMicros = firstFullFrameMicros + frame
  }

  func updatePlan(_ value: SignalPlan) {
    controlLock.lock()
    plan = value
    controlLock.unlock()
  }

  func updateVolume(_ value: Double) {
    controlLock.lock()
    volume = value
    controlLock.unlock()
  }

  func cancel() {
    controlLock.lock()
    running = false
    controlLock.unlock()
  }

  /** 按采样的实际目标输出时间计算包络，无文件、无排队播放段、无帧间重建。 */
  func render(timestamp: UnsafePointer<AudioTimeStamp>, frames: AVAudioFrameCount,
              buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    if controlLock.try() {
      cachedPlan = plan
      cachedRunning = running
      cachedVolume = volume
      controlLock.unlock()
    }
    let rate = 48_000.0
    let host = timestamp.pointee.mHostTime
    let valid = timestamp.pointee.mFlags.contains(.hostTimeValid) && host != 0
    let seconds = valid ? AVAudioTime.seconds(forHostTime: host) : Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    let base = anchorUtcMicros + Int64((seconds - Double(anchorMonoNanos) / 1e9 + latency) * 1e6)
    let list = UnsafeMutableAudioBufferListPointer(buffers)
    var problem: String?
    for index in 0..<Int(frames) {
      let utc = base + Int64(Double(index) / rate * 1e6)
      var target = cachedRunning ? 1.0 : 0.0
      if cachedRunning && valid {
        if !continuous && utc >= singleEndMicros {
          target = 0
        } else {
          let position = (utc - cachedPlan.baseMicros) / 10_000
          if position >= 0 && position < Int64(cachedPlan.levels.count) {
            let level = cachedPlan.levels[Int(position)]
            target = level == 1 ? 1 : (level == 0 ? 0.316227766 : 0)
          } else {
            target = 0
            problem = "时间码计划已过期"
          }
        }
      }
      gain += (target - gain) * 0.12
      // 保留与 Android 一致的 16 bit 量化，再交给浮点音频管线。
      let sample = Float(Int16((sin(phase * 2 * .pi) * gain * cachedVolume * 30_000).rounded())) / 32768
      for buffer in list {
        buffer.mData?.assumingMemoryBound(to: Float.self)[index] = sample
      }
      phase += frequency / rate
      if phase >= 1 { phase -= 1 }
    }
    if statsLock.try() {
      rendered += Int64(frames)
      locked = valid
      failure = problem
      if !valid && DispatchTime.now().uptimeNanoseconds - createdNanos > 2_000_000_000 {
        failure = "无法锁定 macOS 音频时钟"
      }
      statsLock.unlock()
    }
    return noErr
  }

  /** 主线程读取快照，渲染线程不创建字典或发送 Flutter 消息。 */
  func status() -> (values: [String: Any], finished: Bool, error: String?) {
    statsLock.lock()
    let count = rendered
    let ready = locked
    let error = failure
    statsLock.unlock()
    let utc = anchorUtcMicros + Int64(DispatchTime.now().uptimeNanoseconds - anchorMonoNanos) / 1000
    return (["state": ready ? "running" : "calibrating",
             "frames": max(0, (utc - firstFullFrameMicros) / (frameSeconds * 1_000_000)),
             "playUtcMicros": utc, "clockLocked": ready, "frequency": frequency,
             "writtenFrames": count], !continuous && utc >= singleEndMicros, error)
  }
}

/** macOS 连续授时后端，所有 AVAudioEngine 图操作与 Flutter 回调都在主线程执行。 */
final class MacSignalAudioEngine {
  private var engine: AVAudioEngine?
  private var source: AVAudioSourceNode?
  private var session: MacSignalSession?
  private var timer: Timer?
  private var observers: [NSObjectProtocol] = []
  private var activity: NSObjectProtocol?
  private var configurationObserver: NSObjectProtocol?
  private let onStatus: ([String: Any]) -> Void

  init(onStatus: @escaping ([String: Any]) -> Void) {
    self.onStatus = onStatus
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
      self?.stop(message: "设备即将睡眠，发波已停止")
    })
  }

  deinit {
    timer?.invalidate()
    session?.cancel()
    engine?.stop()
    if let configurationObserver = configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "clock": result(Int64(DispatchTime.now().uptimeNanoseconds))
      case "start": try start(call.arguments); result(nil)
      case "stop": stop(); result(nil)
      case "volume":
        guard let value = call.arguments as? NSNumber, value.doubleValue.isFinite else { throw invalid("音量参数无效") }
        session?.updateVolume(min(1, max(0, value.doubleValue)))
        result(nil)
      case "updatePlan": session?.updatePlan(try readPlan(call.arguments)); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      stop(message: error.localizedDescription)
      result(FlutterError(code: "MAC_AUDIO", message: error.localizedDescription, details: nil))
    }
  }

  private func invalid(_ message: String) -> NSError { NSError(domain: "DianboAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

  private func readPlan(_ arguments: Any?) throws -> SignalPlan {
    guard let args = arguments as? [String: Any],
          let base = (args["planBaseUtcMicros"] as? NSNumber)?.int64Value,
          base % 60_000_000 == 0,
          let bytes = args["levels"] as? FlutterStandardTypedData,
          !bytes.data.isEmpty, bytes.data.count <= 360_000,
          bytes.data.count % 6000 == 0 else { throw invalid("时间码计划无效") }
    let levels = [UInt8](bytes.data)
    guard levels.allSatisfy({ $0 <= 2 }) else { throw invalid("时间码电平无效") }
    return SignalPlan(baseMicros: base, levels: levels)
  }

  private func start(_ arguments: Any?) throws {
    guard session == nil else { throw invalid("已有发波会话") }
    let plan = try readPlan(arguments)
    guard let args = arguments as? [String: Any],
          let protocolName = args["protocol"] as? String, ["bpc", "jjy"].contains(protocolName),
          let frequency = (args["frequency"] as? NSNumber)?.doubleValue,
          frequency.isFinite, frequency >= 1000, frequency <= 20_000,
          let utc = (args["clockUtcMicros"] as? NSNumber)?.int64Value,
          let mono = (args["clockMonoNanos"] as? NSNumber)?.uint64Value else { throw invalid("授时参数无效") }
    let now = DispatchTime.now().uptimeNanoseconds
    guard now >= mono && now - mono <= 5_000_000_000 else { throw invalid("音频时钟已过期") }
    let volume = (args["volume"] as? NSNumber)?.doubleValue ?? 1
    guard volume.isFinite else { throw invalid("音量参数无效") }
    let current = MacSignalSession(plan: plan, frequency: frequency,
      frameSeconds: protocolName == "bpc" ? 20 : 60, continuous: args["continuous"] as? Bool ?? true,
      utcMicros: utc, monoNanos: mono, volume: min(1, max(0, volume)))
    let audio = AVAudioEngine()
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else { throw invalid("无法建立音频格式") }
    let node = AVAudioSourceNode(format: format) { _, timestamp, frames, buffers in
      current.render(timestamp: timestamp, frames: frames, buffers: buffers)
    }
    audio.attach(node)
    audio.connect(node, to: audio.mainMixerNode, format: format)
    current.latency = audio.outputNode.presentationLatency
    engine = audio
    source = node
    session = current
    audio.prepare()
    do { try audio.start() } catch { stop(); throw error }
    configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
      if self?.session != nil { self?.stop(message: "音频输出设备已变更，请重新开始") }
    }
    activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "电波表正在授时")
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.report() }
  }

  private func report() {
    guard let current = session else { return }
    let status = current.status()
    if let error = status.error {
      stop(message: error)
      onStatus(["state": "error", "message": error])
    } else if status.finished {
      stop(message: "单帧发波完成")
    } else { onStatus(status.values) }
  }

  func stop(message: String = "已停止发波") {
    if let configurationObserver = configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    configurationObserver = nil
    timer?.invalidate()
    timer = nil
    session?.cancel()
    engine?.stop()
    if let node = source { engine?.detach(node) }
    source = nil
    engine = nil
    session = nil
    if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    onStatus(["state": "stopped", "message": message])
  }
}
