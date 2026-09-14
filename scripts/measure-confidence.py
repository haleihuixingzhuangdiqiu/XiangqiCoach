exec(open(__file__.replace('measure-confidence.py','measure-recognizer.py')).read().split('records=[]')[0])
for ix,im in enumerate(imgs):
 side=[labels,labels2][ix]
 for height,q in [(720,.35),(720,.5),(900,.5)]:
  screen=Image.new('RGB',(1280,2781),(45,45,45));screen.paste(im,(12,722));screen=screen.resize((round(1280*height/2781),height),Image.Resampling.BILINEAR)
  buf=io.BytesIO();screen.save(buf,'JPEG',quality=int(q*100));screen=Image.open(io.BytesIO(buf.getvalue()))
  a=cells(screen,(96*screen.width/1280,802*height/2781,1088*screen.width/1280,1220*height/2781))
  ds=np.abs(a.reshape(90,1,-1)-flat[None,:,:]).mean(2)
  good=np.array([ds[i,labs==side[i]].min() for i in range(90)])
  bad=np.array([ds[i,labs!=side[i]].min() for i in range(90)])
  delta=bad-good
  print(ix,height,q,'piece gap min',min(delta[np.array(side)!='.']),'all gap',delta.min(),'pieceMAE',good[np.array(side)!='.'].max(),'emptyMAE',good[np.array(side)=='.'].max())
