from pathlib import Path
from PIL import Image,ImageFilter
import numpy as np,io,json
root=Path(__file__).resolve().parents[1]
imgs=[Image.open(root/'XiangqiCoach/Resources'/f'board-template-{s}.png').convert('RGB') for s in ['red','black']]
labels=list('rheakaehr'+'.........'+'.c.....c.'+'p.p.p.p.p'+'.........'+'.........'+'P.P.P.P.P'+'.C.....C.'+'.........'+'RHEAKAEHR')
labels2=labels.copy();labels2[7*9+4]=labels2[7*9+7];labels2[7*9+7]='.';labels2=labels2[::-1]
labs=np.array(labels+labels2)
rect=(84,80,1088,1220)
def cells(im,rect):
 x,y,w,h=rect;size=min(w/8,h/9)*.84;out=[]
 for r in range(10):
  for c in range(9):
   cx=x+c*w/8;cy=y+r*h/9
   q=(int(np.floor(cx-size/2)),int(np.floor(cy-size/2)),int(np.ceil(cx+size/2)),int(np.ceil(cy+size/2)))
   out.append(np.asarray(im.crop(q).resize((32,32),Image.Resampling.BILINEAR),dtype=np.float32))
 return np.array(out)
base=np.concatenate([cells(i,rect) for i in imgs]);flat=base.reshape(180,-1)
def detail(a,ls):
 d=np.abs(a.reshape(90,1,-1)-flat[None,:,:]).mean(2);best=d.argmin(1); dist=d[np.arange(90),best]
 errs=[(i,str(ls[i]),str(labs[b]),float(dist[i])) for i,b in enumerate(best) if labs[b]!=ls[i]]
 lum=a.mean(3); sharp=(np.abs(np.diff(lum,axis=1)).mean((1,2))+np.abs(np.diff(lum,axis=2)).mean((1,2)))/2
 return dist,sharp,errs
records=[]
for idx,im in enumerate(imgs):
 for height,q in [(720,.35),(720,.5),(720,.7),(900,.5),(1080,.7)]:
  scale=height/2781; canvas=Image.new('RGB',(1280,2781),(45,45,45));canvas.paste(im,(12,722));canvas=canvas.resize((round(1280*scale),height),Image.Resampling.BILINEAR)
  for blur in [0,.6,1,1.5,2]:
   test=canvas.filter(ImageFilter.GaussianBlur(blur)) if blur else canvas
   data=io.BytesIO();test.save(data,format='JPEG',quality=round(q*100));test=Image.open(io.BytesIO(data.getvalue()))
   a=cells(test,(96*test.width/1280,802*height/2781,1088*test.width/1280,1220*height/2781));d,sp,err=detail(a,np.array([labels,labels2][idx]));piece=np.array([labels,labels2][idx])!='.'
   print(idx,height,q,blur,'dist',round(d.mean(),2),round(d.max(),2),'piece sharp min',round(sp[piece].min(),2),'mean',round(sp[piece].mean(),2),'errors',err[:8])
   for i in range(90):records.append(dict(image=idx,height=height,quality=q,blur=blur,label=[labels,labels2][idx][i],distance=float(d[i]),sharpness=float(sp[i])))
(root/'scripts/recognizer-measurements.json').write_text(json.dumps(records))
