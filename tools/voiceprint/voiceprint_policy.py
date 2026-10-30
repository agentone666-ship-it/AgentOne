def verdict(scores,speech_seconds):
 # Scores are cosine similarities, not probabilities or a calibrated guarantee.
 hits=[x for x in scores if x['score']>=0.65]
 if len(hits)>=2 and hits[-1]['end_ms']-hits[0]['start_ms']>=4500:return 'detected'
 if speech_seconds>=8 and len(scores)>=3 and max((x['score'] for x in scores),default=1)<=0.35:return 'not_detected'
 return 'uncertain'
