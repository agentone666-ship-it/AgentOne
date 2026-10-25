import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {performance} from 'node:perf_hooks';
import {planRecall} from '../../plugins/agentone-memory/recall.mjs';
import {MCPClient} from '../../scripts/mcp_client.mjs';
import {reference,recordings,cases as coreCases,challengeCases} from './fixtures.mjs';

import {seed} from './seed.mjs';

const cases=process.argv.includes('--challenge')?challengeCases:coreCases;
const mode=process.argv.includes('--baseline')?'baseline':process.argv.includes('--structured-baseline')?'structured-baseline':'candidate';
const outFlag=process.argv.indexOf('--output'),out=outFlag>=0?resolve(process.argv[outFlag+1]):null;
const root=mkdtempSync(join(tmpdir(),'agentone-recall-benchmark-'));seed(root);
const client=new MCPClient(resolve('plugins/agentone-memory/server.mjs'),root);
const rows=[];
try {
 await client.initialize();
 for(const c of cases) {
  const start=performance.now();let result;
  if(mode.endsWith('baseline')) {
   const plan=planRecall({query:c.query,...reference,...Object.fromEntries(['time_zone','reference_time'].filter(k=>c[k]).map(k=>[k,c[k]]))});
   const args=mode==='baseline'?{query:c.query,limit:5}:{query:[...plan.people,...plan.keywords].join(' '),...(plan.time_window&&!plan.uncertain_time?plan.time_window:{}),...(plan.place_hint?{place_hint:plan.place_hint}:{}),limit:5};
   const r=await client.call('search_memory',args);
   result={candidates:r.results.map(x=>({session_id:x.session_id,segment_id:x.segment_id})),status:r.results.length?'found':'not_found',events:[]};
  } else result=await client.call('recall_context',{query:c.query,...reference,...Object.fromEntries(['time_zone','reference_time'].filter(k=>c[k]).map(k=>[k,c[k]])),limit:5});
  const sessions=[...new Set((result.candidates??[]).map(x=>x.session_id))];
  let bundle=null;
  if(mode==='candidate'&&sessions.length&&c.sessions.includes(sessions[0])) bundle=await client.call('get_context_bundle',{segment_id:result.candidates[0].segment_id});
  const hit=c.sessions.length?c.sessions.includes(sessions[0]):sessions.length===0;
  const recall=c.sessions.length?c.sessions.filter(x=>sessions.includes(x)).length/c.sessions.length:1;
  const eventHit=!c.event||[...(result.events??[]),...(bundle?.events??[])].some(x=>x.event_id===c.event);
  const handoff=bundle?.handoff;
  const actionPass=(!c.task||handoff?.committed.some(x=>x.text===c.task))&&(!c.cancelled||handoff?.cancelled.some(x=>x.text===c.cancelled)&&!handoff?.committed.some(x=>x.text===c.cancelled))&&(!c.proposal||handoff?.proposed.some(x=>x.text===c.proposal)&&!handoff?.committed.some(x=>x.text===c.proposal));
  const statusPass=result.status===c.status;
  rows.push({id:c.id,split:c.split,expected_status:c.status,status:result.status,status_pass:statusPass,expected_audio:c.sessions.length>0,needs_event:!!c.event,needs_action:!!(c.task||c.cancelled||c.proposal),top1:hit,recall_at_5:recall,event_link:eventHit,action_contract:!!actionPass,pass:hit&&recall===1&&statusPass&&eventHit&&actionPass,latency_ms:Math.round((performance.now()-start)*100)/100,sessions});
 }
 const rate=(rs,key)=>rs.length ? rs.filter(x=>x[key]).length+'/'+rs.length : 'n/a';
 const rates=rs=>({positive_top1:rate(rs.filter(x=>x.expected_audio),'top1'),positive_recall_at_5:rs.filter(x=>x.expected_audio).reduce((sum,x)=>sum+x.recall_at_5,0)/Math.max(1,rs.filter(x=>x.expected_audio).length),status_accuracy:rate(rs,'status_pass'),scenario_pass:rate(rs,'pass'),event_link:rate(rs.filter(x=>x.needs_event),'event_link'),action_contract:rate(rs.filter(x=>x.needs_action),'action_contract')});
 const latencies=rows.map(x=>x.latency_ms).sort((a,b)=>a-b);
 const report={benchmark:'agentone-recall-v1',mode,scope:'Synthetic transcript retrieval + evidence/handoff contracts through a real MCP subprocess. Not ASR, speech quality, LLM reasoning or real-world execution.',recordings:recordings.length+240,cases:rows.length,metrics:rates(rows),dev:rates(rows.filter(x=>x.split==='dev')),transfer:rates(rows.filter(x=>x.split==='transfer')),latency_p95_ms:latencies[Math.ceil(latencies.length*.95)-1],rows};
 if(out) writeFileSync(out,JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify({...report,rows:undefined},null,2));
 if(mode==='candidate'&&process.argv.includes('--check')&&rows.some(x=>!x.pass)) process.exitCode=1;
} finally {await client.close();rmSync(root,{recursive:true,force:true})}
