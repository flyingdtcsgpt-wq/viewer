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
  private var renderers: [AVSpeechSynthesizer] = [] // 파일로 만드는 중 (끝날 때까지 붙잡아 둠)

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
    let audio = FlutterMethodChannel(name: "mediashelf/audio", binaryMessenger: messenger)
    audio.setMethodCallHandler { call, result in instance.handleAudio(call, result) }
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
      let u = utterance(text, args)
      pending[ObjectIdentifier(u)] = result
      synth.speak(u)
    case "render":
      // 오디오북 저장: 소리 내지 않고 WAV 파일로
      guard let args = call.arguments as? [String: Any], let text = args["text"] as? String, let path = args["path"] as? String else {
        result(false)
        return
      }
      render(utterance(text, args), path, result)
    case "stop":
      stopAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func utterance(_ text: String, _ args: [String: Any]) -> AVSpeechUtterance {
    let u = AVSpeechUtterance(string: text)
    if let id = args["voice"] as? String, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
      u.voice = v
    } else {
      u.voice = AVSpeechSynthesisVoice(language: "ko-KR")
    }
    let rate = (args["rate"] as? Double) ?? 1.0
    u.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * rate, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
    return u
  }

  private func render(_ u: AVSpeechUtterance, _ path: String, _ result: @escaping FlutterResult) {
    let r = AVSpeechSynthesizer()
    renderers.append(r)
    var file: AVAudioFile?
    var finished = false
    var wrote = false
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    func finish(_ ok: Bool) {
      if finished { return }
      finished = true
      file = nil // 닫아야 머리에 길이가 적힌다
      DispatchQueue.main.async {
        self.renderers.removeAll { $0 === r }
        result(ok)
      }
    }
    r.write(u) { buffer in
      guard let pcm = buffer as? AVAudioPCMBuffer else { return }
      if pcm.frameLength == 0 {
        finish(wrote)
        return
      }
      do {
        if file == nil {
          let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: pcm.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
          ]
          file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
        }
        try file?.write(from: pcm)
        wrote = true
      } catch {
        finish(false)
      }
    }
    // 끝 신호(빈 버퍼)가 오지 않는 경우를 대비
    DispatchQueue.main.asyncAfter(deadline: .now() + 120 + Double(u.speechString.count) / 3) {
      if !finished { r.stopSpeaking(at: .immediate); finish(wrote) }
    }
  }

  // MARK: 오디오 변환 (WAV → M4A)
  private func handleAudio(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard call.method == "encodeM4a", let args = call.arguments as? [String: Any],
          let src = args["src"] as? String, let dst = args["dst"] as? String else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.global(qos: .utility).async {
      var ok = false
      do {
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: src))
        let fmt = input.processingFormat
        let outUrl = URL(fileURLWithPath: dst)
        try? FileManager.default.removeItem(at: outUrl)
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: fmt.sampleRate,
          AVNumberOfChannelsKey: fmt.channelCount,
          AVEncoderBitRateKey: 64000,
        ]
        var output: AVAudioFile? = try AVAudioFile(forWriting: outUrl, settings: settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8192) {
          while input.framePosition < input.length {
            try input.read(into: buf)
            if buf.frameLength == 0 { break }
            try output?.write(from: buf)
          }
          ok = true
        }
        output = nil
      } catch {
        ok = false
      }
      DispatchQueue.main.async { result(ok) }
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
