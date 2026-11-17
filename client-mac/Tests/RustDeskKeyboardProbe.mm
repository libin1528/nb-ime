// 加载本机 RustDesk 自带的 Flutter，只调用键盘转换器；不启动引擎、不发送系统按键。
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <cstdlib>
#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterEmbedderKeyResponder.h"

static int32_t probe(const void* pointer, bool control) {
  @autoreleasepool {
    const char* configured = std::getenv("NBIME_RUSTDESK_FRAMEWORK");
    static void* library = dlopen(configured ? configured :
        "/Applications/RustDesk.app/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS", RTLD_LAZY | RTLD_LOCAL);
    Class responderClass = NSClassFromString(@"FlutterEmbedderKeyResponder");
    if (!library || !responderClass) {
      fprintf(stderr, "RustDesk Flutter keyboard responder is unavailable\n");
      return -1;
    }
    __block bool command = false;
    __block int32_t result = 0;
    FlutterSendEmbedderKeyEvent receive = ^(const FlutterKeyEvent& event,
                                           FlutterKeyEventCallback callback, void* data) {
      // USB HID Usage 页：左 Command = 0xe3，V = 0x19。
      if (event.physical == (control ? 0x700e0 : 0x700e3)) {
        command = event.type == kFlutterKeyEventTypeDown;
        result |= command ? 2 : 4;
      }
      if (event.physical == 0x70019) {
        if (event.type == kFlutterKeyEventTypeDown && command) result |= 1;
        if (event.type == kFlutterKeyEventTypeUp) result |= 16;
      }
      if (callback) callback(true, data);
    };
    FlutterEmbedderKeyResponder* responder = [[responderClass alloc] initWithSendEvent:receive];
    for (NSEvent* event in (__bridge NSArray*)pointer) {
      [responder handleEvent:event callback:^(BOOL handled) {}];
    }
    if (responder.getPressedState.count == 0) result |= 8;
    return result;
  }
}

extern "C" int32_t nbime_rustdesk_keyboard_probe(const void* pointer) { return probe(pointer, false); }
extern "C" int32_t nbime_rustdesk_control_probe(const void* pointer) { return probe(pointer, true); }
