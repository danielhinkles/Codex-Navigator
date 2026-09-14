"""Presentation-only parsing of voice transport envelopes. Source text stays intact."""
import html
import re

ENVELOPE = re.compile(r'\s*<realtime_delegation>\s*([\s\S]*?)\s*</realtime_delegation>\s*')
FIELD = re.compile(r'<(input|transcript_delta)>\s*([\s\S]*?)\s*</\1>')
SPEAKER = re.compile(r'^(user|assistant):[ \t]*', re.M | re.I)
STATUS = re.compile(r'^\s*\[(?:STATUS|COMPLETE)\]\s*')


def clean_response(text):
    """Remove only recognised presentation prefixes, never arbitrary tags/code."""
    text = STATUS.sub('', text, count=1)
    if text.startswith('::codex-realtime-inline{}'):
        text = text[len('::codex-realtime-inline{}'):].lstrip()
    return text


def utterances(text):
    markers = list(SPEAKER.finditer(text))
    if not markers:
        return [{'speaker':'transcript', 'text':text.strip()}] if text.strip() else []
    result = []
    if text[:markers[0].start()].strip():
        result.append({'speaker':'transcript', 'text':text[:markers[0].start()].strip()})
    for i, marker in enumerate(markers):
        end = markers[i+1].start() if i+1 < len(markers) else len(text)
        words = text[marker.end():end].strip()
        if words:
            result.append({'speaker':marker.group(1).lower(), 'text':words})
    return result


def identity(message):
    return message['speaker'], ' '.join(message['text'].split())


def append_delta(existing, incoming):
    # Deltas can repeat the end of a previous handoff. Match only contiguous
    # boundary overlap, not global text, so later repetitions remain intact.
    for size in range(min(len(existing), len(incoming)), 0, -1):
        tail = [identity(m) for m in existing[-size:]]
        for offset in range(len(incoming)-size+1):
            if tail == [identity(m) for m in incoming[offset:offset+size]]:
                if size == len(existing) and offset:
                    existing[:0] = incoming[:offset]
                existing.extend(incoming[offset+size:])
                return
    existing.extend(incoming)


def parse_voice(text):
    """Only parse complete top-level envelopes; quoted examples stay literal."""
    blocks = list(ENVELOPE.finditer(text))
    if not blocks or ENVELOPE.sub('', text).strip():
        return None
    inputs, messages = [], []
    has_transcript = False
    for block in blocks:
        fields = {m.group(1):html.unescape(m.group(2)).strip() for m in FIELD.finditer(block.group(1))}
        if not fields:
            return None
        current = fields.get('input', '')
        delta = fields.get('transcript_delta', '')
        has_transcript = has_transcript or bool(delta)
        incoming = utterances(delta)
        if current:
            inputs.append(current)
            request = {'speaker':'user', 'text':current}
            if not incoming or identity(incoming[-1]) != identity(request):
                incoming.append(request)
        if delta:
            append_delta(messages, incoming)
        else:
            messages.extend(incoming)
    return {'input':'\n\n'.join(inputs), 'messages':messages, 'hasTranscript':has_transcript}


def readable_prompt(text):
    voice = parse_voice(text)
    if voice is None:
        return text
    return voice['input'] or '\n\n'.join(m['text'] for m in voice['messages'] if m['speaker']=='user') or 'Voice conversation'


def present_turns(turns):
    prompts, conversation = [], []
    is_voice = False
    for turn in turns:
        for prompt in turn['prompts']:
            voice = parse_voice(prompt['text'])
            prompts.append(dict(prompt, text=readable_prompt(prompt['text'])))
            if voice is not None:
                is_voice = True
                if voice['hasTranscript']:
                    append_delta(conversation, voice['messages'])
                else:
                    conversation.extend(voice['messages'])
            else:
                conversation.append({'speaker':'user', 'text':prompt['text']})
    return prompts, [dict(m, id='voice-'+str(i)) for i, m in enumerate(conversation)] if is_voice else []
