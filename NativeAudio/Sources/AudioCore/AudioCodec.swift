import AVFoundation
import Foundation
import OpusBridge

public final class AudioCodec {
  private var encoder: OpaquePointer?
  private var decoder: OpaquePointer?
  public let lookahead: Int
  public init() throws {
    var error: Int32 = 0
    encoder = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &error)
    guard error == 0, let e = encoder else { throw AudioFailure("Opus encoder: \(error)") }
    guard sd_configure_encoder(e) == 0 else {
      opus_encoder_destroy(e)
      encoder = nil
      throw AudioFailure("Opus configuration failed")
    }
    lookahead = Int(sd_encoder_lookahead(e))
    decoder = opus_decoder_create(48000, 2, &error)
    guard error == 0, decoder != nil else {
      opus_encoder_destroy(e)
      encoder = nil
      throw AudioFailure("Opus decoder: \(error)")
    }
  }
  deinit {
    if let e = encoder { opus_encoder_destroy(e) }
    if let d = decoder { opus_decoder_destroy(d) }
  }
  public func encode(_ samples: [Float]) throws -> Data {
    guard samples.count == 1920 else { throw AudioFailure("Expected 960 stereo frames") }
    var bytes = [UInt8](repeating: 0, count: 1140)
    let n = opus_encode_float(encoder!, samples, 960, &bytes, 1140)
    guard n > 0 else { throw AudioFailure("Opus encode: \(n)") }
    return Data(bytes.prefix(Int(n)))
  }
  public func decode(_ payload: Data?) throws -> [Float] {
    var pcm = [Float](repeating: 0, count: 1920)
    let n: Int32
    if let p = payload {
      n = p.withUnsafeBytes {
        opus_decode_float(
          decoder!, $0.bindMemory(to: UInt8.self).baseAddress, Int32(p.count), &pcm, 960, 0)
      }
    } else {
      n = opus_decode_float(decoder!, nil, 0, &pcm, 960, 0)
    }
    guard n == 960 else { throw AudioFailure("Opus decode: \(n)") }
    return pcm
  }
  public func resetDecoder() { sd_reset_decoder(decoder) }
}

public final class AudioSource {
  public enum Kind: String { case clicks, tone, file }
  public let name: String
  public let kind: Kind
  private var file: AVAudioFile?
  private var converter: AVAudioConverter?
  private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  private var cursor: UInt64 = 0
  public init(kind: Kind, url: URL? = nil) throws {
    self.kind = kind
    if kind == .file {
      guard let url = url else { throw AudioFailure("Select an audio file") }
      let f = try AVAudioFile(forReading: url)
      guard f.length > 0, let c = AVAudioConverter(from: f.processingFormat, to: format) else {
        throw AudioFailure("Unsupported or empty audio file")
      }
      file = f
      converter = c
      name = url.lastPathComponent
    } else {
      name = kind == .clicks ? "Click track (120 BPM)" : "440 Hz test tone"
    }
  }
  public func frame(at sample: UInt64) throws -> [Float] {
    if let f = file, let c = converter {
      if sample != cursor {
        f.framePosition =
          AVAudioFramePosition(Double(sample) * f.processingFormat.sampleRate / 48000)
          .quotientAndRemainder(dividingBy: f.length).remainder
        c.reset()
      }
      let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
      var conversionError: NSError?
      var readError: Error?
      let status = c.convert(to: output, error: &conversionError) { count, status in
        do {
          if f.framePosition >= f.length { f.framePosition = 0 }
          let input = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: max(1, count))!
          try f.read(into: input, frameCount: max(1, count))
          guard input.frameLength > 0 else {
            status.pointee = .endOfStream
            return nil
          }
          status.pointee = .haveData
          return input
        } catch {
          readError = error
          status.pointee = .endOfStream
          return nil
        }
      }
      if let error = readError { throw error }
      if status == .error {
        throw conversionError ?? AudioFailure("Audio conversion failed") as NSError
      }
      guard output.frameLength == 960, let channels = output.floatChannelData else {
        throw AudioFailure("Incomplete decoded audio frame")
      }
      cursor = sample + 960
      return (0..<960).flatMap { [channels[0][$0], channels[1][$0]] }
    }
    cursor = sample + 960
    var result = [Float]()
    result.reserveCapacity(1920)
    for i in 0..<960 {
      let n = sample + UInt64(i)
      let t = Double(n) / 48000
      let value: Float
      if kind == .tone {
        value = Float(sin(2 * .pi * 440 * t) * 0.15)
      } else {
        let p = Int(n % 24000)
        let wave = sin(2.0 * Double.pi * 1200.0 * Double(p) / 48000.0)
        let envelope = 0.35 * (1.0 - Double(p) / 240.0)
        value = p < 240 ? Float(wave * envelope) : 0
      }
      result.append(value)
      result.append(value)
    }
    return result
  }
}
