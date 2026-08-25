import AVFoundation
import AudioToolbox
import Darwin
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var timestampedAudioCapture: TimestampedAudioCapture?
  private var timestampedAudioChannel: FlutterMethodChannel?
  private var timestampedAudioEvents: FlutterEventChannel?
  private var measurementAudioChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let capture = TimestampedAudioCapture()
    timestampedAudioCapture = capture

    let events = FlutterEventChannel(
      name: "de.lasli.app/timestamped_audio_events",
      binaryMessenger: messenger
    )
    events.setStreamHandler(capture)
    timestampedAudioEvents = events

    let audioChannel = FlutterMethodChannel(
      name: "de.lasli.app/timestamped_audio",
      binaryMessenger: messenger
    )
    audioChannel.setMethodCallHandler { [weak capture] call, result in
      switch call.method {
      case "clockMonotonicNs":
        result(TimestampedAudioCapture.monotonicNanoseconds())
      case "start":
        do {
          try capture?.start()
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "AUDIO_START_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      case "stop":
        capture?.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    timestampedAudioChannel = audioChannel

    let cueChannel = FlutterMethodChannel(
      name: "de.lasli.app/audio",
      binaryMessenger: messenger
    )
    cueChannel.setMethodCallHandler { call, result in
      guard call.method == "playMeasurementStartTone" else {
        result(FlutterMethodNotImplemented)
        return
      }
      AudioServicesPlaySystemSound(SystemSoundID(1057))
      result(nil)
    }
    measurementAudioChannel = cueChannel
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    timestampedAudioCapture?.stop()
    super.applicationWillTerminate(application)
  }
}

private final class TimestampedAudioCapture: NSObject, FlutterStreamHandler {
  private static let sampleRate = 16_000.0
  private static let tapFrames: AVAudioFrameCount = 960

  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var outputFormat: AVAudioFormat?
  private var eventSink: FlutterEventSink?
  private var running = false
  private var tapInstalled = false

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func start() throws {
    if running { return }

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.defaultToSpeaker]
    )
    try session.setPreferredSampleRate(Self.sampleRate)
    try session.setPreferredIOBufferDuration(0.02)
    if let builtInMic = session.availableInputs?.first(where: {
      $0.portType == .builtInMic
    }) {
      try? session.setPreferredInput(builtInMic)
    }
    try session.setActive(true)

    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw TimestampedAudioError.inputUnavailable
    }
    guard let destinationFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Self.sampleRate,
      channels: 1,
      interleaved: true
    ), let converter = AVAudioConverter(
      from: inputFormat,
      to: destinationFormat
    ) else {
      throw TimestampedAudioError.converterUnavailable
    }

    self.converter = converter
    outputFormat = destinationFormat
    running = true

    input.installTap(
      onBus: 0,
      bufferSize: Self.tapFrames,
      format: inputFormat
    ) { [weak self] buffer, time in
      self?.consume(buffer: buffer, time: time)
    }
    tapInstalled = true

    do {
      engine.prepare()
      try engine.start()
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    running = false
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    engine.stop()
    engine.reset()
    converter = nil
    outputFormat = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func consume(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
    guard running,
          let converter,
          let outputFormat else { return }

    let outputFrames = AVAudioFrameCount(
      ceil(
        Double(buffer.frameLength) *
          outputFormat.sampleRate / buffer.format.sampleRate
      ) + 32.0
    )
    guard let output = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: outputFrames
    ) else { return }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(
      to: output,
      error: &conversionError
    ) { _, inputStatus in
      if suppliedInput {
        inputStatus.pointee = .noDataNow
        return nil
      }
      suppliedInput = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error,
          conversionError == nil,
          output.frameLength > 0,
          let samples = output.int16ChannelData?[0] else { return }

    let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
    let data = Data(bytes: samples, count: byteCount)
    let durationNs = Int64(
      Double(output.frameLength) * 1_000_000_000.0 / Self.sampleRate
    )
    let firstSampleNs: Int64
    if time.isHostTimeValid {
      firstSampleNs = Self.nanoseconds(forHostTime: time.hostTime)
    } else {
      firstSampleNs = Self.monotonicNanoseconds() - durationNs
    }
    let deliveryNs = Self.monotonicNanoseconds()

    DispatchQueue.main.async { [weak self] in
      guard self?.running == true else { return }
      self?.eventSink?([
        "pcm": FlutterStandardTypedData(bytes: data),
        "firstSampleTimeNs": firstSampleNs,
        "deliveryTimeNs": deliveryNs,
        "sampleRate": Int(Self.sampleRate),
      ])
    }
  }

  @objc private func handleAudioInterruption(_ notification: Notification) {
    guard running,
          let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
            as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
      return
    }

    if type == .began {
      engine.pause()
      return
    }

    let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey]
      as? UInt ?? 0
    let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
    guard options.contains(.shouldResume) else { return }
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      try engine.start()
    } catch {
      eventSink?(
        FlutterError(
          code: "AUDIO_RESUME_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  static func monotonicNanoseconds() -> Int64 {
    return nanoseconds(forHostTime: mach_absolute_time())
  }

  private static func nanoseconds(forHostTime hostTime: UInt64) -> Int64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let nanoseconds = Double(hostTime) * Double(timebase.numer) /
      Double(timebase.denom)
    return Int64(min(nanoseconds, Double(Int64.max)))
  }
}

private enum TimestampedAudioError: LocalizedError {
  case inputUnavailable
  case converterUnavailable

  var errorDescription: String? {
    switch self {
    case .inputUnavailable:
      return "Das iPhone-Mikrofon ist nicht verfuegbar."
    case .converterUnavailable:
      return "Der Audio-Konverter konnte nicht gestartet werden."
    }
  }
}
