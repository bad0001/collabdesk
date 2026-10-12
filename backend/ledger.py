"""Notion-style typed properties + an independent Markdown page per record."""
import csv
import io
import json
import re
from datetime import date
from common import APIError, field, link

TYPES = {'text','longtext','select','rating','date','url','member','status'}

def privileged(actor): return actor['role'] in {'admin','leader'}
def dump(value): return json.dumps(value, ensure_ascii=False, separators=(',',':'))
def library(row):
    return {'id':row['id'], 'name':row['name'], 'fields':json.loads(row['fields']), 'views':json.loads(row['views']),
            'workerAccess':row['worker_access'], 'version':row['version'], 'createdBy':row['created_by'],
            'createdAt':row['created_at'], 'updatedAt':row['updated_at']}
def record(db, row, actor=None):
    return {'id':row['id'], 'libraryId':row['library_id'], 'title':row['title'], 'values':json.loads(row['values_json']),
            'body':row['body'], 'archived':bool(row['archived']), 'version':row['version'],
            'taskIds':[r[0] for r in db.execute('SELECT x.task_id FROM record_tasks x JOIN tasks t ON t.id=x.task_id WHERE x.record_id=? AND (? OR t.owner_id=?) ORDER BY x.task_id',(row['id'], actor is None or privileged(actor), actor['id'] if actor else ''))],
            'createdBy':row['created_by'], 'createdAt':row['created_at'], 'updatedAt':row['updated_at']}
def visible(db, actor, rid):
    return privileged(actor) or db.execute('''SELECT 1 FROM record_tasks x JOIN tasks t ON x.task_id=t.id
                      WHERE x.record_id=? AND t.owner_id=? LIMIT 1''',(rid,actor['id'])).fetchone() is not None
def get_record(db, actor, rid, write=False):
    row=db.execute('SELECT * FROM records WHERE id=?',(rid,)).fetchone()
    if row is None or not visible(db, actor, rid): raise APIError(404,'记录不存在或不在当前任务范围')
    lib=db.execute('SELECT * FROM libraries WHERE id=?',(row['library_id'],)).fetchone()
    if write and not privileged(actor) and lib['worker_access']!='write': raise APIError(403,'本库与任务相关的记录仅开放阅读')
    return row,lib
def get_library(db,actor,lid):
    row=db.execute('SELECT * FROM libraries WHERE id=?',(lid,)).fetchone()
    if row is None: raise APIError(404,'记录库不存在')
    if not privileged(actor) and not db.execute('''SELECT 1 FROM records r JOIN record_tasks x ON x.record_id=r.id
        JOIN tasks t ON t.id=x.task_id WHERE r.library_id=? AND t.owner_id=? LIMIT 1''',(lid,actor['id'])).fetchone():
        raise APIError(404,'记录库不在当前任务范围')
    return row

def fields_valid(db, fields):
    if not isinstance(fields,list) or not 0<=len(fields)<=30: raise APIError(422,'每个库最多 30 个字段')
    seen={'title'}
    for f in fields:
        if not isinstance(f,dict) or set(f)-{'id','name','type','options'}: raise APIError(422,'字段格式有误')
        fid=f.get('id','')
        if not isinstance(fid,str) or not re.fullmatch('[a-z][a-z0-9_]{0,31}',fid) or fid in seen: raise APIError(422,'字段 ID 要唯一且使用小写字母、数字、下划线')
        seen.add(fid)
        field(f,'name',limit=60,required=True)
        if f.get('type') not in TYPES: raise APIError(422,'字段类型未支持')
        options=f.get('options',[])
        if not isinstance(options,list) or len(options)>50 or any(not isinstance(v,str) or not v.strip() or len(v)>100 for v in options) or len(set(options))!=len(options): raise APIError(422,'选项需为最多 50 个不同文本')
        if f['type'] not in {'select','status'} and options: raise APIError(422,'只有单选和状态字段使用选项')
    return fields

def value_valid(db,f,value):
    if value is None or value=='': return None
    kind=f['type']
    if kind=='rating':
        if type(value) is not int or not 0<=value<=5: raise APIError(422,f"{f['name']} 应为 0–5 的整数")
    else:
        if not isinstance(value,str): raise APIError(422,f"{f['name']} 应为文本")
        if len(value)>(20000 if kind=='longtext' else 2000): raise APIError(422,'字段值过长')
        if kind in {'select','status'} and value not in f.get('options',[]): raise APIError(422,f"{f['name']} 的选项不存在")
        if kind=='date':
            try:
                if date.fromisoformat(value).isoformat()!=value: raise ValueError()
            except ValueError: raise APIError(422,'日期格式为 YYYY-MM-DD')
        if kind=='url': link({'value':value},'value')
        if kind=='member' and not db.execute('SELECT 1 FROM members WHERE id=?',(value,)).fetchone(): raise APIError(422,'成员字段需使用已登记的成员 ID')
    return value

def values_valid(db,fields,values):
    if not isinstance(values,dict) or set(values)-{f['id'] for f in fields}: raise APIError(422,'属性包含未知字段')
    return {f['id']:value_valid(db,f,values[f['id']]) for f in fields if f['id'] in values}

def views_valid(fields,views):
    if not isinstance(views,list) or len(views)>12: raise APIError(422,'最多 12 个视图')
    ids={f['id'] for f in fields}|{'title','createdAt','updatedAt'}
    seen=set()
    for v in views:
        if not isinstance(v,dict) or set(v)-{'id','name','filters','sorts'}: raise APIError(422,'视图格式有误')
        vid=v.get('id','')
        if not isinstance(vid,str) or not re.fullmatch('[a-z][a-z0-9_-]{0,31}',vid) or vid in seen: raise APIError(422,'视图 ID 需唯一')
        seen.add(vid); field(v,'name',limit=60,required=True)
        filters=v.get('filters',[]); sorts=v.get('sorts',[])
        if not isinstance(filters,list) or len(filters)>10 or not isinstance(sorts,list) or len(sorts)>5: raise APIError(422,'视图条件过多')
        for f in filters:
            if not isinstance(f,dict) or set(f)-{'fieldId','op','value'} or f.get('fieldId') not in ids or f.get('op') not in {'equals','not_equals','contains','gte','lte','is_empty'}: raise APIError(422,'视图筛选条件有误')
            if f.get('value') is not None and (type(f['value']) not in {int,str}): raise APIError(422,'筛选值应为文本或整数')
        for s in sorts:
            if not isinstance(s,dict) or set(s)-{'fieldId','descending'} or s.get('fieldId') not in ids or type(s.get('descending',False)) is not bool: raise APIError(422,'排序条件有误')
    return views

def event(db,actor,lid,rid,kind,before,after,stamp):
    db.execute('INSERT INTO record_events(library_id,record_id,kind,actor_id,actor_name,before_json,after_json,timestamp) VALUES(?,?,?,?,?,?,?,?)',
               (lid,rid,kind,actor['id'],actor['name'],dump(before),dump(after),stamp))

def snapshot(db,actor):
    records=[record(db,r,actor) for r in db.execute('SELECT * FROM records ORDER BY id DESC') if visible(db,actor,r['id'])]
    lids={r['libraryId'] for r in records}; rids={r['id'] for r in records}
    libs=[library(r) for r in db.execute('SELECT * FROM libraries ORDER BY id') if privileged(actor) or r['id'] in lids]
    events=[{'id':r['id'],'libraryId':r['library_id'],'recordId':r['record_id'],'kind':r['kind'],
             'actorId':r['actor_id'],'actorName':r['actor_name'],'before':json.loads(r['before_json']),
             'after':json.loads(r['after_json']),'timestamp':r['timestamp']}
            for r in db.execute('SELECT * FROM record_events ORDER BY id DESC')
            if privileged(actor) or (r['record_id'] in rids)]
    if not privileged(actor):
        for e in events:
            for key in ('before','after'):
                obj=e.get(key)
                if isinstance(obj,dict) and 'taskIds' in obj:
                    obj['taskIds']=[tid for tid in obj['taskIds'] if db.execute('SELECT 1 FROM tasks WHERE id=? AND owner_id=?',(tid,actor['id'])).fetchone()]
    return {'libraries':libs,'records':records,'recordEvents':events}

def filtered(records,view,query=''):
    def value(r,key): return r.get(key) if key in {'title','createdAt','updatedAt'} else r['values'].get(key)
    def match(r,f):
        a=value(r,f['fieldId']); b=f.get('value'); op=f['op']
        if op=='is_empty': return a is None or a==''
        if op=='equals': return a==b
        if op=='not_equals': return a!=b
        if op=='contains': return str(b or '').casefold() in str(a or '').casefold()
        try: return a is not None and ((a>=b) if op=='gte' else (a<=b))
        except TypeError: return False
    result=[r for r in records if not r['archived'] and (not query or query.casefold() in r['title'].casefold()) and all(match(r,f) for f in view.get('filters',[]))]
    for s in reversed(view.get('sorts',[])):
        filled=[r for r in result if value(r,s['fieldId']) is not None and value(r,s['fieldId'])!='']
        empty=[r for r in result if r not in filled]
        result=sorted(filled,key=lambda r:value(r,s['fieldId']),reverse=s.get('descending',False))+empty
    return result

def prepare_record(store,db,actor,lib,data):
    store.reject_unknown(data,{'title','values','body','taskIds','version','archived'})
    title=field(data,'title',limit=200,required=True)
    values=values_valid(db,json.loads(lib['fields']),data.get('values',{}))
    body=data.get('body','')
    if not isinstance(body,str) or len(body)>30000: raise APIError(422,'正文最多 30000 个字符')
    task_ids=data.get('taskIds',[])
    if not isinstance(task_ids,list) or len(task_ids)>50 or any(not isinstance(x,str) for x in task_ids) or len(set(task_ids))!=len(task_ids): raise APIError(422,'关联任务列表格式有误')
    for tid in task_ids: store.get_task(db,actor,tid)
    if not privileged(actor) and (lib['worker_access']!='write' or not task_ids): raise APIError(403,'Worker 只能写入与自己任务关联且已开放写入的记录')
    archived=data.get('archived',False)
    if type(archived) is not bool: raise APIError(422,'archived 应为布尔值')
    return title,values,body,task_ids,archived

def insert(store,db,actor,lib,data,kind="created"):
    title,values,body,task_ids,archived=prepare_record(store,db,actor,lib,data); stamp=store.now()
    c=db.execute('INSERT INTO records(library_id,title,values_json,body,archived,created_by,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)',
                 (lib['id'],title,dump(values),body,int(archived),actor['id'],stamp,stamp))
    db.executemany('INSERT INTO record_tasks VALUES(?,?)',[(c.lastrowid,tid) for tid in task_ids])
    result=record(db,db.execute('SELECT * FROM records WHERE id=?',(c.lastrowid,)).fetchone())
    event(db,actor,lib['id'],c.lastrowid,kind,None,result,stamp); return result

def apply(store,db,actor,path,data):
    if path=='/v1/libraries':
        if not privileged(actor): raise APIError(403,'记录库由 Leader 或用户建立')
        store.reject_unknown(data,{'name','fields','views','workerAccess'})
        name=field(data,'name',limit=100,required=True); fields=fields_valid(db,data.get('fields',[])); views=views_valid(fields,data.get('views',[]))
        access=data.get('workerAccess','write')
        if access not in {'read','write'}: raise APIError(422,'Worker 权限为 read/write')
        stamp=store.now(); c=db.execute('INSERT INTO libraries(name,fields,views,worker_access,created_by,created_at,updated_at) VALUES(?,?,?,?,?,?,?)',(name,dump(fields),dump(views),access,actor['id'],stamp,stamp))
        result=library(db.execute('SELECT * FROM libraries WHERE id=?',(c.lastrowid,)).fetchone()); event(db,actor,c.lastrowid,None,'library_created',None,result,stamp)
        return 201,{'library':result}
    m=re.fullmatch(r'/v1/libraries/(\d+)/(settings|records|import)',path)
    if m:
        lid,action=int(m[1]),m[2]; lib=get_library(db,actor,lid)
        if action=='settings':
            if not privileged(actor): raise APIError(403,'字段、视图及范围由 Leader 或用户管理')
            store.reject_unknown(data,{'version','name','fields','views','workerAccess'})
            if type(data.get('version')) is not int or data['version']!=lib['version']: raise APIError(409,'记录库已更新，请刷新')
            before=library(lib); fields=fields_valid(db,data.get('fields',before['fields'])); views=views_valid(fields,data.get('views',before['views']))
            for row in db.execute('SELECT values_json FROM records WHERE library_id=?',(lid,)):
                values_valid(db,fields,json.loads(row[0])) # refuse a schema change that destroys existing properties
            access=data.get('workerAccess',lib['worker_access'])
            if access not in {'read','write'}: raise APIError(422,'Worker 权限为 read/write')
            db.execute('UPDATE libraries SET name=?,fields=?,views=?,worker_access=?,version=version+1,updated_at=? WHERE id=?',
                       (field(data,'name',lib['name'],100,True),dump(fields),dump(views),access,store.now(),lid))
            result=library(db.execute('SELECT * FROM libraries WHERE id=?',(lid,)).fetchone()); event(db,actor,lid,None,'library_updated',before,result,store.now())
            return 200,{'library':result}
        if action=='records': return 201,{'record':insert(store,db,actor,lib,data)}
        if not privileged(actor): raise APIError(403,'批量导入由 Leader 或用户进行')
        store.reject_unknown(data,{'format','content'})
        content=data.get('content','')
        if not isinstance(content,str) or not content.strip() or len(content)>60000: raise APIError(422,'导入内容格式或长度有误')
        try:
            if data.get('format')=='json': rows=json.loads(content)
            elif data.get('format')=='csv':
                reader=csv.DictReader(io.StringIO(content.lstrip("\ufeff")),strict=True); headers=reader.fieldnames or []
                allowed={f['id'] for f in json.loads(lib['fields'])}|{'title','body','taskIds'}
                if 'title' not in headers or len(set(headers))!=len(headers) or set(headers)-allowed: raise ValueError('CSV 表头需包含 title，其他为字段 ID、body、taskIds')
                rows=[]; field_types={f['id']:f['type'] for f in json.loads(lib['fields'])}
                for row in reader:
                    if None in row or any(v is None for v in row.values()): raise ValueError('CSV 列数不一致')
                    props={k:(int(v) if field_types.get(k)=='rating' and v else v) for k,v in row.items() if k in field_types}
                    rows.append({'title':row['title'],'values':props,'body':row.get('body',''),'taskIds':[x.strip() for x in row.get('taskIds','').split(';') if x.strip()]})
            else: raise ValueError('format 为 json/csv')
        except (ValueError,TypeError,csv.Error) as e: raise APIError(422,f'导入格式有误：{e}')
        if not isinstance(rows,list) or not 1<=len(rows)<=100 or any(not isinstance(r,dict) for r in rows): raise APIError(422,'每批导入 1–100 条对象；更大文件请分批')
        for r in rows: prepare_record(store,db,actor,lib,r)
        result=[insert(store,db,actor,lib,r,"imported") for r in rows]
        return 201,{'imported':len(result),'recordIds':[r['id'] for r in result]}
    m=re.fullmatch(r'/v1/records/(\d+)',path)
    if m:
        rid=int(m[1]); row,lib=get_record(db,actor,rid,True)
        if type(data.get('version')) is not int or data['version']!=row['version']: raise APIError(409,'记录已更新，请刷新后保存')
        before=record(db,row); merged={**before,**data}
        # Workers preserve links they cannot see and cannot remove the last grant.
        if not privileged(actor) and 'taskIds' in data and data['taskIds']!=before['taskIds']: raise APIError(403,'记录与任务的关联由 Leader 或用户调整')
        fields={k:merged[k] for k in ('title','values','body','archived')}; fields['taskIds']=before['taskIds']
        if privileged(actor): fields['taskIds']=data.get('taskIds',before['taskIds'])
        if not privileged(actor):
            own=[tid for tid in before['taskIds'] if db.execute('SELECT 1 FROM tasks WHERE id=? AND owner_id=?',(tid,actor['id'])).fetchone()]
            fields['taskIds']=own
        title,values,body,_,archived=prepare_record(store,db,actor,lib,fields)
        store.reject_unknown(data,{'title','values','body','taskIds','version','archived'})
        db.execute('UPDATE records SET title=?,values_json=?,body=?,archived=?,version=version+1,updated_at=? WHERE id=?',(title,dump(values),body,int(archived),store.now(),rid))
        if privileged(actor):
            db.execute('DELETE FROM record_tasks WHERE record_id=?',(rid,)); db.executemany('INSERT INTO record_tasks VALUES(?,?)',[(rid,t) for t in fields['taskIds']])
        result=record(db,db.execute('SELECT * FROM records WHERE id=?',(rid,)).fetchone()); event(db,actor,lib['id'],rid,'updated',before,result,store.now())
        return 200,{'record':record(db,db.execute('SELECT * FROM records WHERE id=?',(rid,)).fetchone(),actor)}
    return None
