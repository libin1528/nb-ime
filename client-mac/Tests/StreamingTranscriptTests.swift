import Foundation
@main enum StreamingTranscriptTests {
 static func main() {
  var s = StreamingTranscript()
  precondition(s.update(start:0,end:1,text:"我们") == "我们")
  precondition(s.update(start:0,end:2,text:"我们测试") == "我们测试")
  precondition(s.update(start:2,end:3,text:"麦克风") == "我们测试麦克风")
  precondition(s.update(start:2,end:4,text:"麦克风输入") == "我们测试麦克风输入")
  precondition(s.update(start:0,end:4,text:"我们正在测试") == "我们正在测试")
  precondition(s.update(start:4,end:5,text:"🙂") == "我们正在测试🙂")
  precondition(s.update(start:4,end:5,text:"") == "我们正在测试")
  print("StreamingTranscript: 7 checks passed")
 }
}
