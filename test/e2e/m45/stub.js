// SSE chat-completions stub for the X3 mission CLI e2e (docs/specs/mission-cli.md).
// Serves POST */chat/completions with scripted streams — the M3 role script in
// the openai chat dialect. One response per request, in order, shared across
// the start and resume legs (the process stays up for the whole run.sh).
// Prints the bound port on stdout; binds 127.0.0.1 only.
'use strict';
const http = require('http');

const text = (s) => ({ kind: 'text', s });
const tool = (id, name, args) => ({ kind: 'tool', id, name, args });

const script = [
  // Leg 1: po, planner, executor (tool+done) ×2 tasks, verifier.
  text('{"objective":"Ship the gizmo","acceptance":"greeting written and count run"}'),
  text('{"tasks":["write a greeting file","count to 500"]}'),
  tool('t-greet', 'bash', '{"command":"echo hello > greeting.txt"}'),
  text('wrote the greeting'),
  tool('t-count', 'bash', '{"command":"seq 1 500"}'),
  text('counted'),
  text('{"passed":true,"reason":"acceptance met"}'),
  // Resume leg: one executor turn + one verifier turn.
  text('resumed and finished the count'),
  text('{"passed":true,"reason":"acceptance met"}'),
  // Leg 5 (vault checkpoint): the same mission shape as leg 1.
  text('{"objective":"Ship the gizmo","acceptance":"greeting written and count run"}'),
  text('{"tasks":["write a greeting file","count to 500"]}'),
  tool('t-greet5', 'bash', '{"command":"echo hello > greeting.txt"}'),
  text('wrote the greeting'),
  tool('t-count5', 'bash', '{"command":"seq 1 500"}'),
  text('counted'),
  text('{"passed":true,"reason":"acceptance met"}'),
  // Leg 7 (MCP servers boot): the same mission shape as leg 1.
  text('{"objective":"Ship the gizmo","acceptance":"greeting written and count run"}'),
  text('{"tasks":["write a greeting file","count to 500"]}'),
  tool('t-greet7', 'bash', '{"command":"echo hello > greeting.txt"}'),
  text('wrote the greeting'),
  tool('t-count7', 'bash', '{"command":"seq 1 500"}'),
  text('counted'),
  text('{"passed":true,"reason":"acceptance met"}'),
];
let i = 0;

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || !req.url.endsWith('/chat/completions')) {
    res.writeHead(404);
    res.end();
    return;
  }
  req.resume();
  req.on('end', () => {
    const step = script[i++];
    if (!step) {
      res.writeHead(500);
      res.end('script exhausted');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const send = (o) => res.write('data: ' + JSON.stringify(o) + '\n\n');
    if (step.kind === 'text') {
      send({ choices: [{ index: 0, delta: { content: step.s } }] });
      send({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] });
    } else {
      send({
        choices: [{
          index: 0,
          delta: {
            tool_calls: [{
              index: 0,
              id: step.id,
              function: { name: step.name, arguments: step.args },
            }],
          },
        }],
      });
      send({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] });
    }
    send({ choices: [], usage: { prompt_tokens: 10, completion_tokens: 5 } });
    res.write('data: [DONE]\n\n');
    res.end();
  });
});

server.listen(0, '127.0.0.1', () => {
  console.log(String(server.address().port));
});
