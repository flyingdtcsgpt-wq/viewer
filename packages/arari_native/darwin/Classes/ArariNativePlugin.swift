import AVFoundation
import Foundation
import Vision
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// 글자 인식(Vision) · 기기 음성(AVSpeechSynthesizer)
public class ArariNativePlugin: NSObject, FlutterPlugin, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  private var pending: [ObjectIdentifier: FlutterResult] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ArariNativePlugin()
    instance.synth.delegate = instance
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let ocr = FlutterMethodChannel(name: "mediashelf/ocr", binaryMessenger: messenger)
    ocr.setMethodCallHandler { call, result in instance.handleOcr(call, result) }
    let tts = FlutterMethodChannel(name: "mediashelf/tts", binaryMessenger: messenger)
    tts.setMethodCallHandler { call, result in instance.handleTts(call, result) }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }

  // MARK: 글자 인식
  private func handleOcr(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard call.method == "recognize", let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let url = URL(fileURLWithPath: path)
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["ko-KR", "en-US"]
      let handler = VNImageRequestHandler(url: url, options: [:])
      do {
        try handler.perform([request])
        let obs = (request.results ?? []).sorted { a, b in
          // 위에서 아래로, 같은 줄이면 왼쪽부터 (Vision 좌표는 아래가 0)
          let dy = b.boundingBox.maxY - a.boundingBox.maxY
          if abs(dy) > 0.01 { return dy < 0 }
          return a.boundingBox.minX < b.boundingBox.minX
        }
        let text = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        DispatchQueue.main.async { result(text) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "ocr", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  // MARK: 기기 음성
  private func handleTts(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "voices":
      let list = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("ko") || $0.language.hasPrefix("en") }
        .sorted { ($0.language.hasPrefix("ko") ? 0 : 1, $0.name) < ($1.language.hasPrefix("ko") ? 0 : 1, $1.name) }
        .map { "\($0.identifier)|\($0.language)|local|\($0.name)" }
      result(list)
    case "speak":
      guard let args = call.arguments as? [String: Any], let text = args["text"] as? String else {
        result(false)
        return
      }
      stopAll()
      let u = AVSpeechUtterance(string: text)
      if let id = args["voice"] as? String, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
        u.voice = v
      } else {
        u.voice = AVSpeechSynthesisVoice(language: "ko-KR")
      }
      let rate = (args["rate"] as? Double) ?? 1.0
      u.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * rate, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
      pending[ObjectIdentifier(u)] = result
      synth.speak(u)
    case "stop":
      stopAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func stopAll() {
    let waiting = pending
    pending.removeAll()
    synth.stopSpeaking(at: .immediate)
    for r in waiting.values { r(false) }
  }

  public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
    pending.removeValue(forKey: ObjectIdentifier(u))?(true)
  }

  public func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
    pending.removeValue(forKey: ObjectIdentifier(u))?(false)
  }
}
