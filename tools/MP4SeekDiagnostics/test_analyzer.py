import unittest
from analyze import analyze

class AnalysisTests(unittest.TestCase):
 def test_overlap_is_not_added_and_missing_end_is_explicit(self):
  raw=[]
  def row(phase,t,**kw):
   raw.append({'run':1,'sequence':len(raw)+1,'event':'mp4Seek','fields':{'trace':1,'epoch':7,'phase':phase,'nativeClock':t,**kw},'dropped':0,'writerFailures':0})
  row(1,10,seekTarget=42);row(2,10.01)
  link=dict(bridgeID=2,request=3,chunkID=4,readSeekEpoch=7)
  row(20,10.02,rangeLower=0,rangeUpper=100,**link)
  row(40,10.03,cacheOverlapBytes=40,cacheHoleBytes=60,**link)
  row(30,10.04,sourceCallID=1,session=8,startedAt=10.04,**link)
  row(50,10.05,sourceCallID=1,session=9,startedAt=10.05,**link)
  row(51,10.15,sourceCallID=1,session=9,startedAt=10.05,finishedAt=10.15,**link)
  row(31,10.16,sourceCallID=1,session=8,startedAt=10.04,finishedAt=10.16,**link)
  row(41,10.17,bytes=100,usedCacheBytes=40,queuedAt=10.02,startedAt=10.03,finishedAt=10.17,**link)
  row(22,10.18,**link);row(3,10.2);row(7,10.21,framePTS=42)
  out=analyze(raw+raw)['events'][0];read=out['reads'][0]
  self.assertAlmostEqual(out['entryToDeliveryMS'],210)
  self.assertAlmostEqual(out['firstSameEpochChunkResponse']['seekIssuedToResponseMS'],170)
  self.assertAlmostEqual(out['firstSameEpochChunkResponse']['responseToFirstFrameDeliveryMS'],30)
  self.assertAlmostEqual(read['sourceCalls']['sumMS'],120)
  self.assertAlmostEqual(read['smbLibraryCalls']['sumMS'],100)
  self.assertAlmostEqual(read['queueWaitMS'],10)
  self.assertEqual(read['classification'],'mixed_cache_and_smb_api')
  self.assertIn('terminal',out['missingBoundaries'])
  self.assertNotIn('decodeMS',out)
  self.assertEqual(out['sequenceGapsInsideEvent'],[])
  missing=analyze([r for r in raw if r['sequence']!=6])['events'][0]
  self.assertEqual(missing['sequenceGapsInsideEvent'],[[6,6]])
  self.assertEqual(missing['reads'][0]['smbLibraryCalls']['matchedStarts'],0)
 def test_cross_epoch_without_cache_completion_remains_unknown(self):
  raw=[{'run':1,'sequence':1,'event':'mp4Seek','fields':{'trace':2,'epoch':9,'phase':24,'nativeClock':1,'bridgeID':1,'request':2,'chunkID':3,'readSeekEpoch':8,'rangeLower':0,'rangeUpper':8}}]
  read=analyze(raw)['events'][0]['reads'][0]
  self.assertTrue(read['differentReadEpoch']);self.assertEqual(read['classification'],'unknown')
  self.assertIsNone(read['queueWaitMS'])
  self.assertFalse(read['bridgeResponseObserved'])
  self.assertIsNone(analyze(raw)['events'][0]['firstSameEpochChunkResponse'])

 def test_early_probe_is_not_valid_delivery_and_callback_is_separate(self):
  phases=[(1,10,{'seekTarget':24}),(2,10.001,{}),(12,10.002,{'rate':2,'detail':1}),
   (14,10.01,{'available':0,'queryPTS':0}),(15,10.02,{'available':1,'queryPTS':0}),
   (13,10.10,{'outcome':1}),(3,10.11,{}),(7,10.12,{'framePTS':24,'playerTime':24.01,'queryPTS':24.01})]
  records=[{'run':1,'sequence':i+1,'event':'mp4Seek','fields':{'trace':1,'epoch':1,'phase':n,'nativeClock':t,**f}} for i,(n,t,f) in enumerate(phases)]
  out=analyze(records)['events'][0]
  self.assertAlmostEqual(out['seekIssuedToEarlyPlayMS'],1)
  self.assertAlmostEqual(out['callbackToAwaitResumeMS'],10)
  self.assertAlmostEqual(out['entryToDeliveryMS'],120)
  self.assertEqual(out['pendingOutputAvailableUnqualified']['queryPTS'],0)
  self.assertEqual(out['firstDeliveredPTS'],24)
  self.assertEqual(out['firstDeliveryPlayerTime'],24.01)
  self.assertIn('outputAvailable',out['missingBoundaries'])

if __name__=='__main__':unittest.main()
