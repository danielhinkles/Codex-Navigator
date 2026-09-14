"""Explicit native Codex project creation. Organisation gestures never call this."""
from pathlib import Path


def project_params(obj):
    name=obj.get('name','').strip()
    path=obj.get('path','')
    key=obj.get('idempotencyKey','')
    if not name or len(name)>200:
        raise ValueError('Enter a project name of up to 200 characters.')
    if not isinstance(path,str) or not Path(path).is_absolute() or not Path(path).is_dir():
        raise ValueError('Choose or create an available project folder.')
    if not isinstance(key,str) or not key.strip():
        raise ValueError('Missing project creation request ID.')
    return dict(name=name,roots=[dict(path=str(Path(path).resolve()))],idempotencyKey=key)


def list_projects(rpc):
    projects=[];cursor=None;seen=set()
    while True:
        response=rpc.request('project/list',dict(limit=100,cursor=cursor))
        projects.extend(response['data'])
        cursor=response.get('nextCursor')
        if not cursor: return projects
        if cursor in seen: raise ValueError('Codex returned a repeated project-list cursor.')
        seen.add(cursor)


def create_project(rpc, params):
    # Reopening a folder uses its existing project without renaming it.
    root=str(Path(params['roots'][0]['path']).resolve())
    for project in list_projects(rpc):
        if any(str(Path(r['path']).resolve()) == root for r in project.get('roots',[])):
            return project
    result=rpc.request('project/create',params)
    project=result['project']
    if not project.get('id') or not project.get('roots'):
        raise ValueError('Codex did not return a complete project. Retry to check its status.')
    return project
