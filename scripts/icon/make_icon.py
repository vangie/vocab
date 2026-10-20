# Source of the app icon (Resources/AppIcon/icon_1024.png). Then run scripts/icon/build_icns.sh.
# Needs Pillow + numpy and Noto Serif CJK Bold (Source Han Serif Bold works too); override with FONT=/path.
# Colors: deep teal body, amber bookmark ribbon. The glyph is optically centred (see below).
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops
FONT=os.environ.get("FONT","/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc")
FONT_INDEX=int(os.environ.get("FONT_INDEX","0"))  # 0 = SC in the Noto .ttc
CH="生"; GLYPH=420
TOP=(0x16,0x80,0x80); BOT=(0x0A,0x5C,0x62); RIB=(0xE8,0xAA,0x42)
S=1024; sc=4; W=S*sc
pad=100*sc; r=185*sc   # Big Sur grid: 824px body
img=Image.new("RGBA",(W,W),(0,0,0,0))
sh=Image.new("RGBA",(W,W)); ImageDraw.Draw(sh).rounded_rectangle([pad,pad+12*sc,W-pad,W-pad+12*sc],r,fill=(0,0,0,80))
img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(18*sc)))
y=np.linspace(0,1,W)[:,None,None]
grad=Image.fromarray(np.broadcast_to(np.array(TOP)*(1-y)+np.array(BOT)*y,(W,W,3)).astype("uint8")).convert("RGBA")
mask=Image.new("L",(W,W)); ImageDraw.Draw(mask).rounded_rectangle([pad,pad,W-pad,W-pad],r,fill=255)
body=Image.new("RGBA",(W,W)); body.paste(grad,(0,0),mask)
rb=Image.new("L",(W,W)); x0=W-pad-230*sc; x1=x0+110*sc; y1=pad+190*sc
ImageDraw.Draw(rb).polygon([(x0,0),(x1,0),(x1,y1),((x0+x1)//2,y1-45*sc),(x0,y1)],fill=255)
body.paste(Image.new("RGBA",(W,W),RIB+(255,)),(0,0),ImageChops.multiply(rb,mask))
img.alpha_composite(body)
# glyph mask cropped to its ink
f=ImageFont.truetype(FONT,GLYPH*sc,index=FONT_INDEX)
m=Image.new("L",(GLYPH*sc*2,)*2); ImageDraw.Draw(m).text((GLYPH*sc//2,)*2,CH,font=f,fill=255)
gm=m.crop(m.getbbox()); a=np.asarray(gm,float); ys,xs=np.nonzero(a); w=a[ys,xs]
# Optical centre = midpoint of ink-bbox centre and ink centroid (visual mass), placed on icon centre (+small drop)
ox=(gm.width/2+(xs*w).sum()/w.sum())/2; oy=(gm.height/2+(ys*w).sum()/w.sum())/2
cx,cy=int(W/2-ox),int(W/2+8*sc-oy)
gs=Image.new("RGBA",(W,W)); gs.paste(Image.new("RGBA",gm.size,(0,0,0,70)),(cx,cy+8*sc),gm)
img.alpha_composite(gs.filter(ImageFilter.GaussianBlur(8*sc)))
img.paste(Image.new("RGBA",gm.size,(255,255,255,255)),(cx,cy),gm)
out=os.environ.get("OUT","Resources/AppIcon/icon_1024.png")
img.resize((S,S),Image.LANCZOS).save(out)
print("Wrote",out)
