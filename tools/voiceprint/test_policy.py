import unittest
from voiceprint_policy import verdict
class PolicyTests(unittest.TestCase):
 def test_no_speech_or_short_speech_is_uncertain(self):
  self.assertEqual(verdict([],0),'uncertain')
  self.assertEqual(verdict([{'start_ms':0,'end_ms':3000,'score':.2}],3),'uncertain')
 def test_strong_evidence_and_conservative_absence(self):
  self.assertEqual(verdict([{'start_ms':i*1500,'end_ms':i*1500+3000,'score':.8}for i in range(2)],4.5),'detected')
  self.assertEqual(verdict([{'start_ms':i*1500,'end_ms':i*1500+3000,'score':.2}for i in range(5)],9),'not_detected')
  self.assertEqual(verdict([{'start_ms':i*1500,'end_ms':i*1500+3000,'score':.5}for i in range(5)],9),'uncertain')
if __name__=='__main__':unittest.main()
