import unittest,tempfile,json
from pathlib import Path
from core import run

class Tests(unittest.TestCase):
 def test_script(self):self.assertTrue(run(json.loads(Path('example.json').read_text()))['segments'])
 def test_empty(self):
  with self.assertRaises(ValueError):run({})
 def test_bad_action(self):
  with self.assertRaises(ValueError):run({'action':'publish'})
 def test_transcript(self):
  r=run({'action':'transcript','segments':[{'start':0,'end':2,'text':'sample'}],'edits':[{'type':'split','index':0,'at':1,'texts':['one','two']},{'type':'review','index':0}]});self.assertEqual(len(r['segments']),2);self.assertFalse(r['all_reviewed'])
 def test_quality_empty(self):self.assertIsNone(run({'action':'quality'})['selected'])
 def test_ffmpeg_cut(self):
  import subprocess
  with tempfile.TemporaryDirectory() as d:
   src=Path(d)/'synthetic.mp4';dst=Path(d)/'cut.mp4'
   subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=blue:s=64x64:r=10:d=2','-c:v','libx264',str(src)],check=True,timeout=30)
   r=run({'action':'cut','input':str(src),'output':str(dst),'segments':[[0,0.6]]});self.assertLess(r['duration'],1)
   with self.assertRaises(ValueError):run({'action':'cut','input':str(src),'output':str(dst),'segments':[[0,1]]})

if __name__=="__main__":unittest.main()

class MediaComponentTests(unittest.TestCase):
 def test_audio_validation(self):
  import wave
  from audio_validation import inspect_audio,AudioValidationError
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'synthetic.wav'
   with wave.open(str(path),'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(bytes(32000))
   self.assertEqual(inspect_audio(path,extension='.wav',max_minutes=1).duration_seconds,1)
   with self.assertRaises(AudioValidationError):inspect_audio(path,extension='.mp3',max_minutes=1)
 def test_energy_activity(self):
  self.assertEqual(run({'action':'voice_activity','samples':[0.0]*1024})['segments'],[])
  self.assertTrue(run({'action':'voice_activity','samples':[0.5]*1024})['segments'])
