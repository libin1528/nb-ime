#!/usr/bin/env python3
"""在已解锁的 macOS 测试桌面运行原生重输回归。需要调用进程的辅助功能权限。

默认创建并清理临时目录；--workdir 可保留测试日志。
只打开隔离测试窗口和菜单，使用独立剪贴板，不启动输入法或连接远端。
"""
import argparse,os,pathlib,subprocess,time,plistlib,json,tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workdir',type=pathlib.Path)
args=parser.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1]
temporary=None if args.workdir else tempfile.TemporaryDirectory(prefix='nbime-retype-native-')
root=(args.workdir or pathlib.Path(temporary.name)).resolve();root.mkdir(parents=True,exist_ok=True)
os.chdir(root)
def run(cmd,log=None,timeout=180):
 with open(log,'w') if log else open(os.devnull,'w') as f:
  r=subprocess.run([str(x) for x in cmd],stdout=f if log else None,stderr=subprocess.STDOUT if log else None,timeout=timeout)
 if log:print(pathlib.Path(log).read_text()[-5000:],flush=True)
 if r.returncode:raise SystemExit(r.returncode)
src=sorted((repo/'client-mac/Sources').glob('*.swift'));common=[p for p in src if p.name!='main.swift'];c=['xcrun','swiftc','-swift-version','5','-target','arm64-apple-macosx26.0','-module-cache-path','module-cache']

testbundle=root/'NativeFocusTests.app';(testbundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
(testbundle/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.newbaselab.nbime.retype-tests',CFBundleName='NBIME Retype Tests',CFBundleExecutable='NativeFocusTests',CFBundlePackageType='APPL',LSUIElement=True)))
run(c+common+[repo/'client-mac/Tests/RetypeNativeTests.swift','-o',testbundle/'Contents/MacOS/NativeFocusTests'])
run(['codesign','--force','--sign','-',str(testbundle)])
bundle=root/'FocusHost.app';(bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
info=dict(CFBundleIdentifier='com.newbaselab.nbime.focus-fixture',CFBundleName='NBIME Focus Fixture',CFBundleExecutable='FocusHost',CFBundlePackageType='APPL',LSMinimumSystemVersion='26.0')
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
run(c+['-parse-as-library',repo/'client-mac/Tests/RetypeFocusHost.swift','-o',bundle/'Contents/MacOS/FocusHost']);run(['codesign','--force','--sign','-',str(bundle)])
peers=root/'peers';peers.mkdir(exist_ok=True)
for name in ['nbime-focus-test','other-test']:(peers/(name+'.toml')).write_text("allow_swap_key = false\n[info]\nplatform = 'Windows'\n")
os.environ['FOCUS_TEST_DIR']=str(root)
(root/'host.pid').unlink(missing_ok=True);(root/'command.json').unlink(missing_ok=True);(root/'ack.json').unlink(missing_ok=True)
host=subprocess.Popen([str(bundle/'Contents/MacOS/FocusHost')],stdout=open('host.log','w'),stderr=subprocess.STDOUT)
try:
 end=time.monotonic()+10
 while not (root/'host.pid').exists():
  if host.poll() is not None or time.monotonic()>end:raise SystemExit('Focus fixture failed to start')
  time.sleep(.05)
 run([testbundle/'Contents/MacOS/NativeFocusTests'],log='NativeFocusTests.log',timeout=90)
finally:
 (root/'command.json').write_text(json.dumps(dict(serial=999999,op='quit')))
 try:host.wait(timeout=4)
 except subprocess.TimeoutExpired:host.terminate();host.wait(timeout=4)
