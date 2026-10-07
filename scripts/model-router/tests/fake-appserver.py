"""Synthetic stdio peer; never reads account configuration."""
import json,sys,time,subprocess,os
from pathlib import Path
scenario=sys.argv[1];overrides={};args=sys.argv[2:]
for i,a in enumerate(args):
 if a=='-c':
  k,v=args[i+1].split('=',1);overrides[k]=json.loads(v)
def emit(x):print(json.dumps(x,ensure_ascii=False),flush=True)
def event(m,p):emit({'method':m,'params':p})
for line in sys.stdin:
 q=json.loads(line);m=q['method'];rid=q.get('id')
 if m=='initialized':continue
 if m=='initialize':
  if scenario=='stdin':time.sleep(30)
  if scenario in ('oversize','unicode-output'):emit({'padding':('x' if scenario=='oversize' else chr(38634))*(1048577 if scenario=='oversize' else 400000)});continue
  if scenario=='startup-lifecycle':event('thread/started',{'thread':{'id':'t','turns':[]}});continue
  if scenario=='backlog':
   for _ in range(80):event('remoteControl/status/changed',{'status':'disabled'})
   continue
  assert q['params']['capabilities']['experimentalApi'] is True
  emit({'id':rid,'result':{}});event('remoteControl/status/changed',{'status':'connected' if scenario=='remote' else 'disabled','installationId':'synthetic','serverName':'synthetic'});continue
 if m=='config/read':
  c={'features':{k.split('.')[1]:v for k,v in overrides.items() if k.startswith('features.')},'agents':{'enabled':overrides.get('agents.enabled')},'tools':{'experimental_request_user_input':{'enabled':overrides.get('tools.experimental_request_user_input.enabled')}},'forced_login_method':'chatgpt','web_search':'disabled','project_doc_max_bytes':0,'model_provider':'openai','secret':'SYNTHETIC_SECRET_SENTINEL','mcp_servers':{}}
  for key in ('developer_instructions','instructions'):c[key]=overrides.get(key,'HOSTILE_INSTRUCTION_SENTINEL')
  if scenario.startswith('instruction:'):
   _,key,mode=scenario.split(':')
   if mode=='missing':c.pop(key)
   else:c[key]='HOSTILE_INSTRUCTION_SENTINEL' if mode=='enabled' else None
  if scenario.startswith('new-control:'):
   _,key,mode=scenario.split(':'); target=c['agents'] if key=='agents' else c['tools']['experimental_request_user_input']
   if mode=='missing':target.pop('enabled')
   else:target['enabled']=True if mode=='enabled' else 'false'
  for n in ('layered','safe-id'):c['mcp_servers'][n]={'enabled':overrides.get('mcp_servers.'+n+'.enabled',True)}
  if scenario.startswith('feature:'):
   _,key,mode=scenario.split(':')
   if mode=='missing':c['features'].pop(key)
   else:c['features'][key]=True if mode=='enabled' else 'false'
  if scenario=='unsupported-id':c['mcp_servers']['quoted.id']={'enabled':True}
  if scenario.startswith('scalar:'):
   _,key,mode=scenario.split(':')
   if mode=='missing':c.pop(key,None)
   else:c[key]={'web_search':'auto','forced_login_method':'api','project_doc_max_bytes':1}.get(key,'unsupported')
  if scenario=='provider-override':c['model_providers']={'openai':{'base_url':'https://synthetic.invalid'}}
  if scenario.startswith('provider-shape:'):
   c['model_providers']={'null':None,'list':[],'nested':{'openai':[]},'scalar':{'openai':'bad'}}[scenario.split(':')[1]]
  if scenario=='inventory-limit':c['mcp_servers']={str(i):{} for i in range(129)}
  if scenario.startswith('mcp:') and 'mcp_servers.layered.enabled' in overrides:
   mode=scenario.split(':')[1]
   if mode=='missing':c['mcp_servers']['layered'].pop('enabled')
   else:c['mcp_servers']['layered']['enabled']=True if mode=='enabled' else 'false'
  if scenario=='control':c['features'].pop('hooks')
  if scenario=='config':c=None
  if scenario=='error-response':emit({'id':rid,'error':{'message':'SYNTHETIC_SECRET_SENTINEL'}});continue
  layers=[{}]*65 if scenario=='layer-limit' else [{'name':{'type':'user','file':'synthetic'},'config':{'model_instructions_file':'HOSTILE_ROLE_SENTINEL'}}] if scenario=='dirty-layer' else []
  emit({'id':rid+1 if scenario=='response' else rid,'result':{'config':c,'layers':layers}});continue
 if m=='thread/start':
  if scenario.startswith('warning:'):
   mode=scenario.split(':')[1]
   text='Code Mode is unavailable because code-mode host is disabled. Code mode will fail closed; enable `features.code_mode_host` and install `codex-code-mode-host`.'
   event('configWarning' if mode=='config' else 'warning',{'threadId':'old' if mode=='stale' else 't','message':text if mode in ('exact','stale','config','duplicate') else text+' changed'})
   if mode=='duplicate':event('warning',{'threadId':'t','message':text})
  p=q['params'];assert p['environments']==[] and p['ephemeral'] is True and p['dynamicTools']==[] and p['selectedCapabilityRoots']==[] and p['allowProviderModelFallback'] is False
  assert p['model']=='gpt-6.1-sol' and p['config']['model_reasoning_effort']=='high'
  assert p['developerInstructions']==''
  assert p['baseInstructions']==('You are a benchmark response generator. Solve the supplied task from its prompt '
   'and embedded fixtures only. Return only the requested answer text in one final response. '
   'Do not use tools, inspect files, execute commands, ask questions, or describe planned actions.')
  emit({'id':rid,'result':{'model':'gpt-6-luna' if scenario=='model' else p['model'],'reasoningEffort':'high','modelProvider':'openai','thread':{'id':'' if scenario=='id' else 't','turns':[]}}});continue
 if m=='turn/start':
  p=q['params'];assert p['environments']==[] and p['model']=='gpt-6.1-sol' and p['effort']=='high'
  if scenario=='images':
   assert p['input'][0]=={'type':'text','text':'Synthetic fixture\nexact bytes'}
   assert len(p['input'])==3 and all(i['type']=='localImage' for i in p['input'][1:])
   Path(os.environ['BENCH_IMAGE_EVIDENCE']).write_text(json.dumps(p['input']))
   event('item/started',{'threadId':'t','turnId':'u','item':{'type':'userMessage','id':'user','content':p['input']}})
  else:assert p['input']==[{'type':'text','text':'Synthetic fixture\nexact bytes'}]
  if scenario in ('timeout','descendant'):
   if scenario=='descendant':
    child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'])
    Path(os.environ['BENCH_DESCENDANT_EVIDENCE']).write_text(json.dumps({'pid':child.pid,'parent':os.getpid(),'cwd':str(Path.cwd())}))
   time.sleep(30)
  emit({'id':rid,'result':{'turn':{'id':'u','items':[],'status':'inProgress','error':None}}});base={'threadId':'t','turnId':'u'}
  if scenario=='valid-lifecycle':
   event('thread/started',{'thread':{'id':'t','turns':[]}});event('turn/started',dict(base,turn={'id':'u','items':[]}));event('thread/settings/updated',{'threadId':'t','threadSettings':{'model':'gpt-6.1-sol','modelProvider':'openai','effort':'high'}})
   event('thread/status/changed',{'threadId':'t','status':{'type':'active','activeFlags':[]}})
  if scenario=='malformed-delta':event('item/agentMessage/delta',dict(base,itemId='d',delta=123));continue
  if scenario=='malformed-index':event('item/reasoning/summaryPartAdded',dict(base,itemId='r',summaryIndex=True));continue
  if scenario.startswith('reasoning-index:'):
   mode=scenario.split(':')[1];params=dict(base,itemId='r',delta='text')
   if mode!='missing':params['contentIndex']=True if mode=='bool' else '0' if mode=='string' else 0
   event('item/reasoning/textDelta',params)
   if mode!='valid':continue
  if scenario=='malformed-status':event('thread/status/changed',{'threadId':'t','status':{'type':'active','activeFlags':'bad'}});continue
  if scenario=='malformed-params':event('item/agentMessage/delta',[]);continue
  if scenario in ('nested-thread-id','thread-history'):event('thread/started',{'thread':{'id':'t' if scenario=='thread-history' else None,'turns':[{'items':[{'type':'mcpToolCall'}]}] if scenario=='thread-history' else []}});continue
  if scenario in ('nested-turn-id','turn-items'):event('turn/started',dict(base,turn={'id':None if scenario=='nested-turn-id' else 'u','items':[] if scenario=='nested-turn-id' else [{'type':'mcpToolCall'}]}));continue
  if scenario.startswith('malformed:'):event('item/completed',dict(base,item={'id':'x','type':scenario.split(':')[1],'text':123,'content':[123],'summary':[123]}));continue
  if scenario.startswith('delta:'):event('item/agentMessage/delta',dict(base,itemId='' if scenario=='delta:missing' else 'd',turnId='old' if scenario=='delta:stale' else 'u',delta='text'));continue
  if scenario.startswith('settings:'):event('thread/settings/updated',{'threadId':'' if scenario=='settings:id' else 't','threadSettings':{'model':'gpt-6-luna' if scenario=='settings:model' else 'gpt-6.1-sol','modelProvider':'openai','effort':'high'}});continue
  if scenario=='reroute-id':event('model/rerouted',{'fromModel':'gpt-6.1-sol','toModel':'gpt-6-luna'});continue
  if scenario=='request':emit({'id':88,'method':'item/tool/call','params':base});continue
  if scenario in ('unknown','error'):event('UNKNOWN_SECRET_SENTINEL' if scenario=='unknown' else 'error',base);continue
  if scenario in ('reroute','reroute-stale'):event('model/rerouted',dict(base,turnId='old' if scenario=='reroute-stale' else 'u',fromModel='gpt-6.1-sol',toModel='gpt-6-luna',reason='modelUnavailable'));continue
  if scenario.startswith('item:'):event('item/completed',dict(base,item={'id':'i','type':scenario[5:]}));continue
  last={'inputTokens':100,'cachedInputTokens':40,'cacheWriteInputTokens':5,'outputTokens':8,'reasoningOutputTokens':2,'totalTokens':108}
  if scenario=='usage':last.pop('outputTokens')
  if scenario=='cache-write-omitted':last.pop('cacheWriteInputTokens')
  if scenario=='cache-write-zero':last['cacheWriteInputTokens']=0
  if scenario.startswith('cache-write-invalid:'):
   last['cacheWriteInputTokens']={'null':None,'true':True,'false':False,'nan':float('nan'),'inf':float('inf'),'negative-inf':float('-inf'),'negative':-1,'string':'0','list':[],'object':{},'float':0.0}[scenario.split(':')[1]]
  if scenario=='nonfinite':last['inputTokens']=float('nan')
  if scenario=='cache-invalid':last['cacheWriteInputTokens']=101
  if scenario=='usage-stale':event('thread/tokenUsage/updated',dict(base,turnId='old',tokenUsage={'last':last}));continue
  if scenario=='usage-cumulative':last={'inputTokens':50,'cachedInputTokens':20,'cacheWriteInputTokens':0,'outputTokens':4,'reasoningOutputTokens':0,'totalTokens':54}
  total=dict(last)
  if scenario=='usage-cumulative':total={k:v*3 for k,v in last.items()}
  if scenario=='usage-multistep':total['totalTokens']+=2
  if scenario=='usage-total-missing':total=None
  if scenario!='usage-missing':event('thread/tokenUsage/updated',dict(base,tokenUsage={'last':last,'total':total}))
  if scenario in ('usage-duplicate','usage-retry'):event('thread/tokenUsage/updated',dict(base,tokenUsage={'last':last,'total':total}))
  # The live server echoes the user turn as a raw message first; a localImage input arrives as an input_image data URL.
  user_content=[{'type':'input_text','text':'Synthetic fixture\nexact bytes'}]
  if scenario in ('images','raw-image-unrequested'):user_content.append({'type':'input_image','image_url':'data:image/png;base64,c3ludGhldGljIFBORw==','detail':'auto'})
  event('rawResponseItem/completed',dict(base,item={'id':'raw-user','type':'message','role':'user','content':user_content}))
  raw={'id':'raw-final','type':'message','role':'assistant','phase':'final_answer','content':[{'type':'output_text','text':'synthetic answer'}]}
  if scenario!='raw-missing':event('rawResponseItem/completed',dict(base,item={'type':'function_call'} if scenario=='raw-tool' else raw))
  if scenario not in ('raw-missing','usage-missing'):
   event('rawResponse/completed',dict(base,responseId='old' if scenario=='raw-stale' else 'resp-1',usage=None if scenario=='raw-null' else last))
   if scenario=='raw-stale':event('rawResponse/completed',dict(base,turnId='old',responseId='resp-2',usage=last))
   if scenario=='raw-duplicate':event('rawResponse/completed',dict(base,responseId='resp-1',usage=last))
   if scenario=='usage-cumulative':
    event('rawResponse/completed',dict(base,responseId='resp-2',usage=last))
    event('rawResponse/completed',dict(base,responseId='resp-3',usage=last))
   if scenario=='usage-retry':event('rawResponse/completed',dict(base,responseId='resp-2',usage=last))
  if scenario=='quota-valid':event('account/rateLimits/updated',{'rateLimits':{'limitId':'codex','primary':None}})
  if scenario=='quota-weekly':event('account/rateLimits/updated',{'rateLimits':{'limitId':'codex','primary':{'usedPercent':12,'windowDurationMins':300,'resetsAt':1800000000},'secondary':{'usedPercent':66,'windowDurationMins':10080,'resetsAt':1800000000}}})
  if scenario=='quota-invalid':event('account/rateLimits/updated',{'rateLimits':{'primary':{'usedPercent':True}}})
  if scenario=='compaction':event('thread/compacted',base)
  if scenario=='async-input':emit({'id':99,'method':'item/tool/requestUserInput','params':base});continue
  event('item/completed',dict(base,item={'id':'c','type':'agentMessage','text':'commentary','phase':'commentary'}))
  item={'id':'f','type':'agentMessage','text':'synthetic answer','phase':'final_answer'}
  if scenario=='duplicate':event('item/completed',dict(base,item=item))
  if scenario=='benign-field':item['questions']=['unsafe']
  if scenario!='final':event('item/completed',dict(base,item=item))
  turn={'id':'u','items':[item],'status':'failed' if scenario=='failed' else 'completed','error':None}
  if scenario=='nested':turn['items'].append({'id':'unsafe','type':'mcpToolCall'})
  if scenario=='stale':base['turnId']='old'
  event('turn/completed',dict(base,turn=turn))
