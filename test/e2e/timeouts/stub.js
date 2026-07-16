// Silent-provider stub for the timeout e2e: accepts TCP connections and
// never sends a byte — the observed glm/deepseek failure mode (ESTABLISHED
// socket, no response) that motivated the stream guard. Prints the bound
// port on stdout; binds 127.0.0.1 only.
'use strict';
const net = require('net');

const server = net.createServer((socket) => {
  socket.on('data', () => {}); // drain the request, answer nothing
  socket.on('error', () => {});
});
server.listen(0, '127.0.0.1', () => {
  console.log(server.address().port);
});
