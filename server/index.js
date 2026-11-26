#!/usr/bin/env node
/*
  SOLIDWORKS Composer MCP server (v1.1.0)
  - No npm dependencies: speaks MCP (JSON-RPC 2.0, newline-delimited) over stdio itself.
  - Drives SOLIDWORKS Composer on Windows through COM (ProgID DSComposer.Application) via one
    persistent PowerShell process (keeps the COM connection, and so the Composer window, alive).
*/
'use strict';
const path = require('path');
const { spawn } = require('child_process');

const SERVER_INFO = { name: 'composer-mcp', version: '1.1.0' };
const HOST_PS = path.join(__dirname, 'ps', 'host.ps1');
const TIMEOUT_MS = 15 * 60 * 1000;
const MARK = '@@CRMCP@@';

// ---------- persistent PowerShell host ----------
// One long-lived PowerShell keeps the Composer COM object alive between tool calls.
let host = null;          // { child, buffer, pending: Map }
let nextId = 1;
let queue = Promise.resolve();

function startHost() {
  const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-STA',
    '-ExecutionPolicy', 'Bypass', '-File', HOST_PS], { windowsHide: true });
  const h = { child, buffer: '', pending: new Map(), stderr: '' };
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    h.buffer += chunk;
    let idx;
    while ((idx = h.buffer.indexOf('\n')) >= 0) {
      const line = h.buffer.slice(0, idx).trim();
      h.buffer = h.buffer.slice(idx + 1);
      const at = line.indexOf(MARK);
      if (at < 0) continue; // stray output of a user script
      let msg;
      try { msg = JSON.parse(Buffer.from(line.slice(at + MARK.length), 'base64').toString('utf8')); } catch (e) { continue; }
      const p = h.pending.get(msg.id);
      if (p) { h.pending.delete(msg.id); p.resolve(msg.result); }
    }
  });
  child.stderr.on('data', (d) => { h.stderr = (h.stderr + d).slice(-4000); });
  const fail = (why) => {
    for (const p of h.pending.values()) p.resolve({ ok: false, error: why + (h.stderr ? '\n' + h.stderr.trim() : '') });
    h.pending.clear();
    if (host === h) host = null;
  };
  child.on('error', (e) => fail('Could not start PowerShell: ' + e.message));
  child.on('close', (code) => fail('PowerShell host stopped (exit ' + code + ').'));
  return h;
}

function sendToHost(args) {
  if (!host) host = startHost();
  const h = host;
  const id = nextId++;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (h.pending.has(id)) {
        h.pending.delete(id);
        resolve({ ok: false, error: 'Timed out after ' + (TIMEOUT_MS / 60000) + ' minutes; PowerShell host restarted (Composer connection lost).' });
        try { h.child.kill(); } catch (e) { /* ignore */ }
      }
    }, TIMEOUT_MS);
    h.pending.set(id, { resolve: (r) => { clearTimeout(timer); resolve(r); } });
    const payload = Buffer.from(JSON.stringify(Object.assign({ id }, args)), 'utf8').toString('base64');
    h.child.stdin.write(payload + '\n');
  });
}

// Calls run one at a time: Composer's COM server is single-threaded
function runInComposer(args, runner) {
  const exec = runner || sendToHost;
  const p = queue.then(() => exec(args));
  queue = p.catch(() => {});
  return p;
}

const TOOLS = [
  {
    name: 'status',
    description: 'Check or start the connection with SOLIDWORKS Composer. With start=true the MCP opens its own Composer window and keeps it connected; ' +
      'a Composer started by hand cannot be reached. Returns version, open documents and the active one.',
    inputSchema: {
      type: 'object',
      properties: { start: { type: 'boolean', description: 'Open a connected Composer window if none is connected. Default false.' } }
    }
  },
  {
    name: 'open',
    description: 'Open a file (.smg, .smgXml, .smgProj, .stp/.step and other formats Composer imports) in the connected Composer. Starts Composer if needed.',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string', description: 'Absolute Windows path of the file.' } },
      required: ['path']
    }
  },
  {
    name: 'api_reference',
    description: 'Return the full Composer COM API from its type library: IApplication and IDocument methods with parameter names and types, and all enums ' +
      '(CrRender, CrRibbonCommand, CrWorkShop, ...). Read this before writing run_script code.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'run_script',
    description: 'Run PowerShell code in the persistent session. Predefined: $app (connected DSComposer.Application or $null) and $doc (active document or $null). ' +
      'Variables you set with $global: persist between calls. Output is returned as JSON; COM objects come back as "[COM object]". ' +
      'Enums are plain integers, e.g. $doc.RenderMode = 3 (Flat Technical), $app.RunRibbonCommand(32) (3/4 X- Y- Z+).',
    inputSchema: {
      type: 'object',
      properties: { code: { type: 'string', description: 'PowerShell code to run.' } },
      required: ['code']
    }
  },
  {
    name: 'export_svg',
    description: 'Export SVG files through the Technical Illustration workshop (the COM API itself cannot write vector files). ' +
      'Uses the Technical Illustration profile you name (prefix match), or the one currently selected. ' +
      'Default: every view of the active document as <viewname>.svg (Multiple > Views). Give view for one view, or views for a list. ' +
      'Existing files with the same name are overwritten. Composer must have been started by this MCP (status start=true / open).',
    inputSchema: {
      type: 'object',
      properties: {
        folder: { type: 'string', description: 'Absolute Windows output folder; created if missing.' },
        profile: { type: 'string', description: 'Technical Illustration profile name (prefix match), e.g. "Default".' },
        view: { type: 'string', description: 'Export only this view (name as in the Views pane).' },
        views: { type: 'array', items: { type: 'string' }, description: 'Export only these views, one by one.' },
        timeout_s: { type: 'number', description: 'Maximum seconds to wait for Composer to finish. Default 600.' }
      },
      required: ['folder']
    }
  },
  {
    name: 'diagnose',
    description: 'Troubleshoot: Composer COM registration in the registry, running Composer processes and whether this MCP is connected.',
    inputSchema: { type: 'object', properties: {} }
  }
];

async function callTool(name, args, runner) {
  args = args || {};
  if (name === 'status') return runInComposer({ action: 'status', start: !!args.start }, runner);
  if (name === 'open') {
    if (!args.path || typeof args.path !== 'string') throw new Error('path is required');
    return runInComposer({ action: 'open', path: args.path }, runner);
  }
  if (name === 'api_reference') return runInComposer({ action: 'api_reference' }, runner);
  if (name === 'diagnose') return runInComposer({ action: 'diagnose' }, runner);
  if (name === 'export_svg') {
    if (!args.folder || typeof args.folder !== 'string') throw new Error('folder is required');
    return runInComposer({ action: 'export_svg', folder: args.folder, profile: args.profile || null, view: args.view || null,
      views: Array.isArray(args.views) && args.views.length ? args.views : null, timeout_s: args.timeout_s || null }, runner);
  }
  if (name === 'run_script') {
    if (!args.code || typeof args.code !== 'string') throw new Error('code is required');
    return runInComposer({ action: 'run_script', code: args.code }, runner);
  }
  throw new Error('Unknown tool: ' + name);
}

function createServer(options) {
  const runner = (options && options.runner) || null;
  const send = (options && options.send) || ((msg) => process.stdout.write(JSON.stringify(msg) + '\n'));

  async function handle(msg) {
    const { id, method, params } = msg;
    const isRequest = id !== undefined && id !== null;
    const reply = (result) => isRequest && send({ jsonrpc: '2.0', id, result });
    const fail = (code, message) => isRequest && send({ jsonrpc: '2.0', id, error: { code, message } });

    switch (method) {
      case 'initialize':
        return reply({
          protocolVersion: (params && params.protocolVersion) || '2025-06-18',
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions: 'Controls SOLIDWORKS Composer on this Windows PC through its COM API. Start with status (start=true), then open; read api_reference before run_script. For SVG output use export_svg.'
        });
      case 'ping':
        return reply({});
      case 'tools/list':
        return reply({ tools: TOOLS });
      case 'tools/call': {
        try {
          const result = await callTool(params && params.name, params && params.arguments, runner);
          return reply({ content: [{ type: 'text', text: JSON.stringify(result, null, 2) }], isError: !!(result && result.ok === false) });
        } catch (e) {
          return reply({ content: [{ type: 'text', text: 'Error: ' + e.message }], isError: true });
        }
      }
      default:
        if (method && method.startsWith('notifications/')) return;
        return fail(-32601, 'Method not found: ' + method);
    }
  }
  return { handle };
}

function main() {
  process.stderr.write('[composer-mcp] server ' + SERVER_INFO.version + ' listening on stdio\n');
  const server = createServer();
  let buffer = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    buffer += chunk;
    let idx;
    while ((idx = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, idx).trim();
      buffer = buffer.slice(idx + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch (e) {
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }) + '\n');
        continue;
      }
      server.handle(msg).catch((e) => process.stderr.write(String(e && e.stack || e) + '\n'));
    }
  });
}

module.exports = { createServer, callTool, TOOLS };
if (!process.env.COMPOSER_MCP_NO_MAIN) main();
