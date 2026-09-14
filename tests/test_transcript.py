import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from transcript import parse_voice, readable_prompt, present_turns, clean_response
from index import Index


def envelope(request, delta=''):
    return '<realtime_delegation>\n<input>'+request+'</input>\n<transcript_delta>'+delta+'</transcript_delta>\n</realtime_delegation>'

class TranscriptTests(unittest.TestCase):
    def test_input_and_delta_echo_appear_once(self):
        result=parse_voice(envelope('Make it readable.','assistant: What would help?\nuser: Make it readable.'))
        self.assertEqual(result['input'],'Make it readable.')
        self.assertEqual([m['text'] for m in result['messages']],['What would help?','Make it readable.'])
    def test_multiline_speech_and_literal_comparisons_survive(self):
        result=parse_voice(envelope('Is 2 < 3 &amp; 4 > 1?','user: First line\nSecond line'))
        self.assertEqual(result['messages'][0]['text'],'First line\nSecond line')
        self.assertEqual(result['messages'][-1]['text'],'Is 2 < 3 & 4 > 1?')
    def test_input_only_and_missing_input(self):
        self.assertEqual(readable_prompt(envelope('Hello')),'Hello')
        self.assertEqual(readable_prompt(envelope('','user: Hello')),'Hello')
    def test_ordinary_code_and_quoted_examples_are_preserved(self):
        examples=['Hello <input>world</input>', '```xml\n'+envelope('Example')+'\n```','Here is an example: '+envelope('Example'),'<realtime_delegation><input>incomplete']
        for value in examples:
            self.assertIsNone(parse_voice(value))
            self.assertEqual(readable_prompt(value),value)
    def test_boundary_overlap_without_global_deduplication(self):
        turns=[{'prompts':[{'id':'p1','time':1,'text':envelope('Yes','assistant: Is it ready?\nuser: Yes')}]},
               {'prompts':[{'id':'p2','time':2,'text':envelope('Yes','user: Yes\nassistant: Shall I continue?\nuser: Yes')}]}]
        prompts,messages=present_turns(turns)
        self.assertEqual([m['text'] for m in messages],['Is it ready?','Yes','Shall I continue?','Yes'])
        self.assertEqual(len({m['id'] for m in messages}),4)
        self.assertEqual([p['text'] for p in prompts],['Yes','Yes'])
    def test_later_delta_can_supply_earlier_context(self):
        turns=[{'prompts':[{'id':'p1','time':1,'text':envelope('Blue')}]},
               {'prompts':[{'id':'p2','time':2,'text':envelope('Yes','assistant: Which colour?\nuser: Blue\nassistant: Apply blue?\nuser: Yes')}]}]
        _,messages=present_turns(turns)
        self.assertEqual([m['text'] for m in messages],['Which colour?','Blue','Apply blue?','Yes'])
    def test_identical_input_only_requests_are_not_dropped(self):
        turns=[{'prompts':[{'id':str(i),'time':i,'text':envelope('Hello')}]} for i in range(2)]
        _,messages=present_turns(turns)
        self.assertEqual(len(messages),2)
    def test_multiple_envelopes_and_unlabelled_transcript(self):
        parsed=parse_voice(envelope('One')+'\n'+envelope('Two','Some spoken words'))
        self.assertEqual(parsed['input'],'One\n\nTwo')
        self.assertEqual(parsed['messages'][1]['speaker'],'transcript')
    def test_prefix_cleanup_is_voice_only(self):
        self.assertEqual(clean_response('[COMPLETE] Ready.'),'Ready.')
        self.assertEqual(clean_response('Use [STATUS] in this example.'),'Use [STATUS] in this example.')
    def test_cached_history_gets_new_presentation_without_reindex(self):
        with tempfile.TemporaryDirectory() as directory:
            index=Index(directory)
            record={'id':'voice','createdAt':1,'updatedAt':2}
            index.upsert_metadata([record])
            raw=envelope('A readable preview','assistant: What do you want?\nuser: A readable preview')
            projected={'id':'old','start':1,'end':2,'seconds':1,'status':'completed','prompts':[{'id':'p','time':1,'text':raw}], 'last':'[COMPLETE] Ready.','media':[], 'changed':[], 'messages':2}
            with index.db:
                index.db.execute('INSERT INTO turns VALUES(?,?,?)',('voice','old',json.dumps(projected)))
            detail=index.detail('voice')
            self.assertEqual(detail['prompts'][0]['text'],'A readable preview')
            self.assertEqual(detail['lastResponse'],'Ready.')
            self.assertEqual(len(detail['voiceMessages']),2)
            self.assertNotIn('transcript_delta',index.summarize(record)['searchText'])
            self.assertEqual(index.turns('voice')[0]['prompts'][0]['text'],raw)
            index.db.close()
    def test_nonvoice_projection_is_unchanged(self):
        original={'id':'p','time':1,'text':'Show <input> as code.'}
        prompts,messages=present_turns([{'prompts':[original]}])
        self.assertEqual(prompts,[original]);self.assertEqual(messages,[])

if __name__=='__main__':unittest.main()
