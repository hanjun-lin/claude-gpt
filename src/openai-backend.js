// Backend: standard OpenAI Chat Completions with an API key.
// Fallback for when you'd rather bill per-token than use the subscription.

const { sseLines } = require('./anthropic-stream');

const BASE = (process.env.OPENAI_BASE_URL || 'https://api.openai.com/v1').replace(/\/$/, '');

function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.filter((b) => b && b.type === 'text').map((b) => b.text).join('\n');
}

function cleanSchema(node) {
  if (Array.isArray(node)) return node.map(cleanSchema);
  if (!node || typeof node !== 'object') return node;
  const out = {};
  for (const [k, v] of Object.entries(node)) {
    if (k === '$schema' || k === 'cache_control') continue;
    out[k] = cleanSchema(v);
  }
  return out;
}

function toolResultText(block) {
  let out;
  if (typeof block.content === 'string') out = block.content;
  else if (Array.isArray(block.content)) {
    out = block.content
      .map((b) => (b.type === 'text' ? b.text : b.type === 'image' ? '[image omitted]' : ''))
      .filter(Boolean).join('\n');
  } else out = '';
  return block.is_error ? `Error: ${out}` : out || '(no output)';
}

function toMessages(body) {
  const msgs = [];
  const sys = textOf(body.system);
  if (sys) msgs.push({ role: 'system', content: sys });

  for (const m of body.messages || []) {
    if (typeof m.content === 'string') { msgs.push({ role: m.role, content: m.content }); continue; }
    const blocks = Array.isArray(m.content) ? m.content : [];

    if (m.role === 'user') {
      for (const b of blocks) {
        if (b.type === 'tool_result') {
          msgs.push({ role: 'tool', tool_call_id: b.tool_use_id, content: toolResultText(b) });
        }
      }
      const parts = [];
      for (const b of blocks) {
        if (b.type === 'text' && b.text) parts.push({ type: 'text', text: b.text });
        else if (b.type === 'image' && b.source) {
          const url = b.source.type === 'base64'
            ? `data:${b.source.media_type};base64,${b.source.data}`
            : b.source.url;
          if (url) parts.push({ type: 'image_url', image_url: { url } });
        }
      }
      if (parts.length) {
        const onlyText = parts.every((p) => p.type === 'text');
        msgs.push({ role: 'user', content: onlyText ? parts.map((p) => p.text).join('\n') : parts });
      }
      continue;
    }

    const text = blocks.filter((b) => b.type === 'text').map((b) => b.text).join('');
    const calls = blocks.filter((b) => b.type === 'tool_use').map((b) => ({
      id: b.id, type: 'function',
      function: { name: b.name, arguments: JSON.stringify(b.input ?? {}) },
    }));
    const out = { role: 'assistant', content: text || null };
    if (calls.length) out.tool_calls = calls;
    if (out.content || out.tool_calls) msgs.push(out);
  }
  return msgs;
}

function toTools(tools) {
  if (!Array.isArray(tools) || !tools.length) return undefined;
  return tools.filter((t) => t && t.name).map((t) => ({
    type: 'function',
    function: {
      name: t.name,
      description: t.description || '',
      parameters: cleanSchema(t.input_schema || { type: 'object', properties: {} }),
    },
  }));
}

function toToolChoice(tc) {
  if (!tc) return undefined;
  if (tc.type === 'any') return 'required';
  if (tc.type === 'auto') return 'auto';
  if (tc.type === 'none') return 'none';
  if (tc.type === 'tool') return { type: 'function', function: { name: tc.name } };
  return undefined;
}

const STOP = { stop: 'end_turn', length: 'max_tokens', tool_calls: 'tool_use', function_call: 'tool_use' };

async function run(body, model, effort, writer, log) {
  const key = process.env.OPENAI_API_KEY;
  if (!key) throw new Error('OPENAI_API_KEY is not set (required for the openai backend).');

  const payload = {
    model,
    messages: toMessages(body),
    stream: true,
    stream_options: { include_usage: true },
  };
  if (body.max_tokens) payload.max_completion_tokens = body.max_tokens;
  const tools = toTools(body.tools);
  if (tools) {
    payload.tools = tools;
    const choice = toToolChoice(body.tool_choice);
    if (choice) payload.tool_choice = choice;
  }
  if (/^(gpt-5|o\d)/.test(model)) payload.reasoning_effort = effort;
  else if (typeof body.temperature === 'number') payload.temperature = body.temperature;

  const res = await fetch(`${BASE}/chat/completions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw Object.assign(new Error(await res.text()), { status: res.status });

  let finish = 'stop';
  for await (const line of sseLines(res.body)) {
    if (!line.startsWith('data:')) continue;
    const raw = line.slice(5).trim();
    if (!raw || raw === '[DONE]') continue;
    let chunk;
    try { chunk = JSON.parse(raw); } catch { continue; }

    if (chunk.usage) {
      writer.usage = {
        input_tokens: chunk.usage.prompt_tokens ?? 0,
        output_tokens: chunk.usage.completion_tokens ?? 0,
      };
    }
    const ch = chunk.choices && chunk.choices[0];
    if (!ch) continue;
    if (ch.finish_reason) finish = ch.finish_reason;
    const d = ch.delta || {};
    if (d.content) writer.text(d.content);
    for (const tc of d.tool_calls || []) {
      const slot = tc.index ?? 0;
      writer.toolStart(slot, tc.id || `toolu_${slot}_${Date.now()}`, tc.function?.name || 'unknown');
      writer.toolArgs(slot, tc.function?.arguments);
    }
  }
  log('finish_reason', finish);
  return STOP[finish] || null;
}

module.exports = { run };
