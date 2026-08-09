// Emits an Anthropic Messages streaming response, hiding the content-block
// index bookkeeping from the backends.

class AnthropicStreamWriter {
  constructor(res, model) {
    this.res = res;
    this.model = model;
    this.index = -1;
    this.textOpen = false;
    this.tools = new Map(); // backend-specific key -> block index
    this.usage = { input_tokens: 0, output_tokens: 0 };
    this.sawToolCall = false;
  }

  send(event, data) {
    this.res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  }

  start() {
    this.res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      connection: 'keep-alive',
    });
    this.send('message_start', {
      type: 'message_start',
      message: {
        id: 'msg_proxy', type: 'message', role: 'assistant', model: this.model,
        content: [], stop_reason: null, stop_sequence: null,
        usage: { input_tokens: 0, output_tokens: 0 },
      },
    });
  }

  _closeBlock() {
    if (this.index >= 0) this.send('content_block_stop', { type: 'content_block_stop', index: this.index });
  }

  text(delta) {
    if (!delta) return;
    if (!this.textOpen) {
      this._closeBlock();
      this.index += 1;
      this.textOpen = true;
      this.tools.clear();
      this.send('content_block_start', {
        type: 'content_block_start', index: this.index,
        content_block: { type: 'text', text: '' },
      });
    }
    this.send('content_block_delta', {
      type: 'content_block_delta', index: this.index,
      delta: { type: 'text_delta', text: delta },
    });
  }

  toolStart(key, id, name) {
    if (this.tools.has(key)) return;
    this._closeBlock();
    this.textOpen = false;
    this.index += 1;
    this.sawToolCall = true;
    this.tools.set(key, this.index);
    this.send('content_block_start', {
      type: 'content_block_start', index: this.index,
      content_block: { type: 'tool_use', id, name, input: {} },
    });
  }

  toolArgs(key, partial) {
    const idx = this.tools.get(key);
    if (idx === undefined || !partial) return;
    this.send('content_block_delta', {
      type: 'content_block_delta', index: idx,
      delta: { type: 'input_json_delta', partial_json: partial },
    });
  }

  finish(stopReason) {
    this._closeBlock();
    this.send('message_delta', {
      type: 'message_delta',
      delta: { stop_reason: stopReason || (this.sawToolCall ? 'tool_use' : 'end_turn'), stop_sequence: null },
      usage: { output_tokens: this.usage.output_tokens },
    });
    this.send('message_stop', { type: 'message_stop' });
    this.res.end();
  }
}

// Shared SSE line reader for an undici/fetch response body.
async function* sseLines(body) {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    const lines = buf.split('\n');
    buf = lines.pop();
    for (const line of lines) yield line;
  }
  if (buf) yield buf;
}

module.exports = { AnthropicStreamWriter, sseLines };
