import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import { spawnSync } from 'node:child_process';
import { mkdtempSync,mkdirSync,readFileSync,existsSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join,resolve } from 'node:path';
import { MCPClient } from './mcp_client.mjs';

const archive=resolve(process.argv[2] ?? 'build/AgentOne.app.zip');
const temporary=mkdtempSync(join(tmpdir(),'agentone-package-capture-'));
const run=(cmd,args,options={})=>{
  const result=spawnSync(cmd,args,{encoding:'utf8',timeout:30000,maxBuffer:16*1024*1024,...options});
  assert.equal(result.status,0,`${cmd} failed: ${result.stderr || result.error || result.stdout}`);
  return result.stdout.trim();
};
try {
  run('ditto',['-x','-k',archive,temporary]);
  const app=join(temporary,'AgentOne.app');
  run('codesign',['--verify','--deep','--strict',app]);
  assert.equal(existsSync(join(app,'Contents/Resources/AgentOneLifeRuntime')),false);
  assert.equal(existsSync(join(app,'Contents/Resources/AgentOne_AgentOneApp.bundle')),false);
  assert.equal(readFileSync(join(app,'Contents/Resources/laya-worker.py'),'utf8'),readFileSync('tools/laya-decision/worker.py','utf8'));
  const executable=join(app,'Contents/MacOS/AgentOne');
  const check=JSON.parse(run(executable,['--self-check']));
  assert.equal(check.agent_runtime,false);assert.equal(check.recording_started,false);assert.equal(check.recording_output,'mixed');assert.equal(check.schema,2);
  assert.deepEqual(check.sources,['system_audio','microphone']);
  const plist=JSON.parse(run('plutil',['-convert','json','-o','-',join(app,'Contents/Info.plist')]));
  assert.equal(plist.CFBundleShortVersionString,readFileSync('VERSION','utf8').trim());
  assert.equal(plist.LSMinimumSystemVersion,'15.0');
  for(const key of ['NSMicrophoneUsageDescription','NSAudioCaptureUsageDescription','NSSpeechRecognitionUsageDescription']) assert.ok(plist[key]);
  const symbols=run('nm',['-j',executable]);
  assert.doesNotMatch(symbols,/AgentOnePiRuntime|PiSidecarBridge|AgentOneModelAuth/);
  const root=join(temporary,'memory');mkdirSync(root);
  const legacy=new DatabaseSync(join(root,'memory.sqlite'));
  legacy.exec(readFileSync(join(app,'Contents/Resources/agentone-memory/schema.sql'),'utf8').replace("('schema_version', '2')","('schema_version', '1')").replace("'mixed','system_audio'","'system_audio'"));legacy.close();
  const client=new MCPClient(join(app,'Contents/Resources/agentone-memory/server.mjs'),root);
  try {
    await client.initialize();
    assert.equal((await client.request('tools/list')).tools.length,9);
    assert.equal((await client.call('get_capture_status')).capture.state,'not_started');
    assert.equal((await client.call('search_memory')).total_matches,0);
  } finally {await client.close()}
  const upgraded=new DatabaseSync(join(root,'memory.sqlite'));
  assert.equal(upgraded.prepare("SELECT value FROM meta WHERE key='schema_version'").get().value,'2');
  assert.deepEqual(upgraded.prepare('PRAGMA foreign_key_check').all(),[]);upgraded.close();
  console.log('Packaged capture app passed: signature, resource schema self-check, no embedded Agent/Pi runtime, privacy descriptions, product version and actual bundled MCP process. No recording permissions requested.');
} finally {rmSync(temporary,{recursive:true,force:true})}
