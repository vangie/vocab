# Source of the app icon (Resources/AppIcon/icon_1024.png).
# Needs Pillow and a bold CJK font: set FONT below (written on Linux with Noto Sans CJK Bold;
# on macOS e.g. /System/Library/Fonts/PingFang.ttc). Then run scripts/icon/build_icns.sh.
from PIL import Image, ImageDraw, ImageFont, ImageFilter
S=1024; scale=4; W=S*scale
img=Image.new("RGBA",(W,W),(0,0,0,0))
# shadow
pad=100*scale; r=185*scale
sh=Image.new("RGBA",(W,W),(0,0,0,0))
ImageDraw.Draw(sh).rounded_rectangle([pad,pad+12*scale,W-pad,W-pad+12*scale],r,fill=(0,0,0,90))
sh=sh.filter(ImageFilter.GaussianBlur(18*scale))
img.alpha_composite(sh)
# gradient body
grad=Image.new("RGBA",(W,W))
gd=ImageDraw.Draw(grad)
top=(236,64,80); bot=(200,28,52)
for y in range(W):
    t=y/W; gd.line([(0,y),(W,y)],fill=tuple(int(top[i]+(bot[i]-top[i])*t) for i in range(3))+(255,))
mask=Image.new("L",(W,W),0)
ImageDraw.Draw(mask).rounded_rectangle([pad,pad,W-pad,W-pad],r,fill=255)
body=Image.new("RGBA",(W,W),(0,0,0,0)); body.paste(grad,(0,0),mask)
# bookmark ribbon top-right, clipped to body
rib=Image.new("RGBA",(W,W),(0,0,0,0)); rd=ImageDraw.Draw(rib)
x0=W-pad-230*scale; x1=x0+110*scale; y1=pad+190*scale; notch=45*scale
rd.polygon([(x0,0),(x1,0),(x1,y1),((x0+x1)//2,y1-notch),(x0,y1)],fill=(140,14,32,255))
rclip=Image.new("RGBA",(W,W),(0,0,0,0)); rclip.paste(rib,(0,0),Image.composite(rib.split()[3],Image.new("L",(W,W),0),mask))
body.alpha_composite(rclip)
img.alpha_composite(body)
# character
font=ImageFont.truetype("/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",500*scale,index=2)
d=ImageDraw.Draw(img)
bb=d.textbbox((0,0),"生",font=font)
tw,th=bb[2]-bb[0],bb[3]-bb[1]
cx=(W-tw)//2-bb[0]; cy=(W-th)//2-bb[1]+10*scale
d.text((cx,cy),"生",font=font,fill=(255,255,255,255))
img=img.resize((S,S),Image.LANCZOS)
img.save("icon_1024.png")
img.resize((256,256),Image.LANCZOS).save("icon_256.png")
