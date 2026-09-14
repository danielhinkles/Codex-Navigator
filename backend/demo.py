"""Explicit, isolated fixture mode for UI verification. Never mixed with live history."""
import time
import shutil
from pathlib import Path

def seed(index):
    now=time.time()
    names=['Directional animation pass','Movement refinement','Vehicle art integration','Final art integration','Investigate save bug','Testing animation masks','Check failing test','Real Time Voice Chat']
    durations=[94320,42360,13440,8280,4620,2520,480,120]
    rows=[]
    for i,name in enumerate(names):
        tid='demo-'+str(i)
        rows.append({'id':tid,'name':name,'cwd':'/Users/alex/Projects/'+(['Atlas Studio','Harbor Notes','Meadow Engine'][i%3]) if i<7 else '',
                     'createdAt':now-130000-i*86400,'updatedAt':now-i*86400,'source':'Codex Desktop','model':'Codex', 'historyMode':'paginated'})
    index.upsert_metadata(rows)
    for i,r in enumerate(rows):
        prompts=['Generate the directional animation pass.','Add diagonal movement sprites.','Check the animation transitions.','Export the final sprite sheets.'] if i==0 else [names[i]]
        if i == 7:
            prompts = ['<realtime_delegation><input>Could we make the conversation easier to read?</input><transcript_delta>user: Could we make the conversation easier to read?</transcript_delta></realtime_delegation>',
                       '<realtime_delegation><input>Yes, and keep the speakers clearly labelled.</input><transcript_delta>user: Could we make the conversation easier to read?\nassistant: We can show each speaker separately and remove the technical wrapping.\nuser: Yes, and keep the speakers clearly labelled.</transcript_delta></realtime_delegation>']
        turns=[]
        for j,text in enumerate(prompts):
            turns.append({'id':r['id']+'-'+str(j),'status':'inProgress' if i==0 and j==3 else 'completed',
                'startedAt':now-45 if i==0 and j==3 else r['createdAt']+j*1800,
                'completedAt':None if i==0 and j==3 else r['createdAt']+j*1800+durations[i]/len(prompts),
                'durationMs':None if i==0 and j==3 else durations[i]*1000/len(prompts),
                'items':[{'type':'userMessage','id':r['id']+'-p'+str(j),'content':[{'type':'text','text':text}]},
                         {'type':'agentMessage','text':'[COMPLETE] The conversation is now formatted for reading.' if i == 7 else 'The animation pass is ready for review.'}]})
        fixture=Path(__file__).resolve().parent.parent/'demo-preview.png'
        if not fixture.exists():fixture=Path.cwd()/'codex-navigator-mockup.png'
        if i == 0 and fixture.exists():
            for n in range(3):
                copy=index.directory/('demo-image-'+str(n+1)+'.png')
                shutil.copyfile(fixture,copy)
                turns[0]['items'].append({'type':'agentMessage','text':'Preview fixture: '+str(copy)})
        index.cache_page(r['id'],turns,None,index.fingerprint(r['id']),True)
