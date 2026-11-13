// 使用合成文件按真实语速喂入生产 LocalPreview；不录音、不上传。
import AVFoundation
import Foundation

enum Log { static func w(_ s: String) { print(s) } }
@main enum LocalPreviewProbe {
 @MainActor static func main() async throws {
  let file = try AVAudioFile(forReading: URL(fileURLWithPath:CommandLine.arguments[1]))
  let src = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:UInt32(file.length))!
  try file.read(into:src)
  let format = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false)!
  let out = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:UInt32(Double(src.frameLength)*16000/src.format.sampleRate+100))!
  let converter = AVAudioConverter(from:src.format,to:format)!
  var fed=false;var error:NSError?
  converter.convert(to:out,error:&error) { _,status in
   if fed { status.pointee = .endOfStream; return nil }; fed=true; status.pointee = .haveData; return src
  }
  let samples=Array(UnsafeBufferPointer(start:out.floatChannelData![0],count:Int(out.frameLength)))
  let preview=LocalPreview()
  for round in 1...2 {
   preview.prepare(language:"auto")
   let deadline=Date().addingTimeInterval(15)
   while !preview.ready && Date()<deadline { try await Task.sleep(for:.milliseconds(50)) }
   precondition(preview.ready,"本地模型未预热")
   var count=0, first:Double?, last=""
   let start=Date()
   preview.onText = { text in count += 1; last=text; if first == nil { first=Date().timeIntervalSince(start) } }
   precondition(preview.start())
   for i in stride(from:0,to:samples.count,by:1600) {
    preview.append(Array(samples[i..<min(i+1600,samples.count)]))
    try await Task.sleep(for:.milliseconds(100))
   }
   precondition(first != nil && first! < Double(samples.count)/16000,"必须在音频结束前返回文字")
   precondition(count>5 && last.contains("麦克风"),"实际识别应连续返回中间文字")
   preview.stop(); let stoppedCount=count
   preview.append(samples)
   try await Task.sleep(for:.milliseconds(300))
   precondition(count==stoppedCount,"取消后不能回调旧文字")
   print(String(format:"ROUND %d first=%.3fs updates=%d text=%@",round,first!,count,last))
  }
  preview.prepare(language:"zz-XX")
  try await Task.sleep(for:.seconds(1))
  precondition(!preview.ready && !preview.start(),"不支持语言回退远端")
  preview.stop()
  print("LocalPreview lifecycle PASS")
 }
}
