import { existsSync } from 'node:fs';
import { resolve,join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { memoryRoot } from '../plugins/agentone-memory/store.mjs';

const app=process.argv[2];
const server=app ? join(resolve(app),'Contents/Resources/agentone-memory/server.mjs') : fileURLToPath(new URL('../plugins/agentone-memory/server.mjs',import.meta.url));
if(!existsSync(server)) throw new Error('MCP server was not found at the selected installation');
console.log(JSON.stringify({mcpServers:{'agentone-memory':{command:process.execPath,args:[server],env:{AGENTONE_MEMORY_HOME:memoryRoot()}}}},null,2));
