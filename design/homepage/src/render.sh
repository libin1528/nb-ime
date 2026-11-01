#!/bin/zsh
# 把首页示意图和截图拼图渲染成 PNG：design/readme/{arch,pipeline,capsule-states,settings}-{zh,en,ja}{,-dark}.png
# 要装 Google Chrome 和 Python 的 Pillow（用来裁掉底下多余的背景）。
set -euo pipefail
cd "${0:A:h}"
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT=../../readme
for d in arch pipe states settings; do
  case $d in
    arch) page="diagrams.html?d=arch"; name=arch ;;
    pipe) page="diagrams.html?d=pipe"; name=pipeline ;;
    states) page="gallery.html?g=states"; name=capsule-states ;;
    settings) page="gallery.html?g=settings"; name=settings ;;
  esac
  for lang in zh en ja; do
    for theme in light dark; do
      suffix=""; [[ $theme == dark ]] && suffix="-dark"
      f="$OUT/$name-$lang$suffix.png"
      "$CH" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
        --screenshot="$f" --window-size=960,2000 "file://$PWD/$page&lang=$lang&theme=$theme" 2>/dev/null
      python3 - "$f" <<'EOF'
import sys
from PIL import Image
p = sys.argv[1]
im = Image.open(p).convert("RGB")
bg = im.getpixel((2, im.height - 2))
w, h = im.size
y = h - 1
while y > 0 and all(im.getpixel((x, y)) == bg for x in range(0, w, 7)):
    y -= 1
im.crop((0, 0, w, min(h, y + 60))).save(p, optimize=True)
EOF
      echo "$f"
    done
  done
done
