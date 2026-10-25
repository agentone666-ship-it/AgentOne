import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync,readFileSync,existsSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join,resolve } from 'node:path';
import { MCPClient } from './mcp_client.mjs';

const archive=resolve(process.argv[2] ?? 'build/AgentOne.app.zip');
const temporary=mkdtempSync(join(tmpdir(),'agentone-package-capture-'));
const run=(cmd,args,options={})=>{
  const result=spawnSync(cmd,args,{encoding:'utf8',timeout:30000,...options});
  assert.equal(result.status,0,`${cmd} failed: ${result.stderr || result.error || result.stdout}`);
  return result.stdout.trim();
};
try {
  run('ditto',['-x','-k',archive,temporary]);
  const app=join(temporary,'AgentOne.app');
  run('codesign',['--verify','--deep','--strict',app]);
  assert.equal(existsSync(join(app,'Contents/Resources/AgentOneLifeRuntime')),false);
  assert.equal(existsSync(join(app,'Contents/Resources/AgentOne_AgentOneApp.bundle')),false);
  const executable=join(app,'Contents/MacOS/AgentOne');
  const check=JSON.parse(run(executable,['--self-check']));
  assert.equal(check.agent_runtime,false);assert.equal(check.recording_started,false);
  assert.deepEqual(check.sources,['system_audio','microphone']);
  const plist=JSON.parse(run('plutil',['-convert','json','-o','-',join(app,'Contents/Info.plist')]));
  assert.equal(plist.CFBundleShortVersionString,readFileSync('VERSION','utf8').trim());
  assert.equal(plist.LSMinimumSystemVersion,'15.0');
  for(const key of ['NSMicrophoneUsageDescription','NSAudioCaptureUsageDescription','NSSpeechRecognitionUsageDescription']) assert.ok(plist[key]);
  const symbols=run('nm',['-j',executable]);
  assert.doesNotMatch(symbols,/AgentOnePiRuntime|PiSidecarBridge|AgentOneModelAuth/);
  const client=new MCPClient(join(app,'Contents/Resources/agentone-memory/server.mjs'),join(temporary,'memory'));
  try {
    await client.initialize();
    assert.equal((await client.request('tools/list')).tools.length,6);
    assert.equal((await client.call('get_capture_status')).capture.state,'not_started');
    assert.equal((await client.call('search_memory')).total_matches,0);
  } finally {await client.close()}
  console.log('Packaged capture app passed: signature, resource schema self-check, no embedded Agent/Pi runtime, privacy descriptions, product version and actual bundled MCP process. No recording permissions requested.');
} finally {rmSync(temporary,{recursive:true,force:true})}
