import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

export class MCPClient {
  constructor(server,home) {
    this.child=spawn(process.execPath,[server,'--home',home],{stdio:['pipe','pipe','pipe']});
    this.pending=new Map();this.id=0;this.stderr='';
    this.child.stderr.on('data',data=>{this.stderr+=data});
    this.lines=createInterface({input:this.child.stdout});
    this.lines.on('line',line=>{
      const response=JSON.parse(line);const p=this.pending.get(response.id);
      if(p){clearTimeout(p.timer);this.pending.delete(response.id);response.error?p.reject(new Error(response.error.message)):p.resolve(response.result)}
    });
    this.exited=new Promise(resolve=>this.child.on('exit',resolve));
  }
  request(method,params={}) {
    return new Promise((resolve,reject)=>{
      const id=++this.id;
      const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error(`MCP timeout: ${this.stderr}`))},10000);
      this.pending.set(id,{resolve,reject,timer});
      this.child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');
    });
  }
  async initialize() {return this.request('initialize',{protocolVersion:'2025-06-18',capabilities:{},clientInfo:{name:'synthetic-interface-harness',version:'1'}})}
  async call(name,args={}) {
    const result=await this.request('tools/call',{name,arguments:args});
    if(result.isError) throw new Error(result.content[0].text);
    return result.structuredContent;
  }
  async close() {
    this.child.stdin.end();
    let timer;
    await Promise.race([this.exited,new Promise(resolve=>{timer=setTimeout(()=>{this.child.kill();resolve()},3000)})]);
    clearTimeout(timer);this.lines.close();
    for(const p of this.pending.values()) clearTimeout(p.timer);
  }
}
