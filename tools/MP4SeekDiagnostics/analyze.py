#!/usr/bin/env python3
"""Offline numeric seek trace analysis; no device, network or product mutations."""
import argparse,json
from collections import defaultdict
from pathlib import Path

PHASES={1:'entered',2:'seekIssued',3:'seekAwaitReturned',4:'outputAvailable',5:'copyStarted',6:'copyReturned',7:'frameDelivered',8:'presentationNotified',9:'terminal',10:'closingState',11:'readChunkLimit',12:'earlyPlayCommand',13:'seekCompletionCallback',14:'pendingOutputProbe',15:'pendingOutputAvailable',20:'bridgeStarted',21:'bridgeReturned',22:'bridgeResponded',23:'bridgeFailed',24:'initialBridge',25:'initialRequest',30:'sourceStarted',31:'sourceReturned',32:'sourceFailed',33:'initialSource',40:'cacheSelection',41:'wrapperReturned',42:'wrapperCancelled',43:'wrapperFailed',44:'initialQueuedWork',45:'cacheSpan',50:'smbStarted',51:'smbReturned',52:'smbFailed'}

def analyze(records):
    # Same record may exist in an incremental snapshot and rotated file.
    unique={(r['run'],r['sequence']):r for r in records}
    runs=defaultdict(list)
    for r in unique.values(): runs[r['run']].append(r)
    gaps={run:[[a['sequence']+1,b['sequence']-1] for a,b in zip(sorted(rows,key=lambda r:r['sequence']),sorted(rows,key=lambda r:r['sequence'])[1:]) if b['sequence']>a['sequence']+1] for run,rows in runs.items()}
    groups=defaultdict(list)
    for r in unique.values():
        if r.get('event')=='mp4Seek' and 'trace' in r['fields']: groups[(r['run'],r['fields']['trace'])].append(r)
    result=[]
    for (run,trace),rows in sorted(groups.items()):
        rows.sort(key=lambda r:r['sequence'])
        fields=[r['fields'] for r in rows]
        def first(phase):return next((v for v in fields if v.get('phase')==phase),{})
        def elapsed(a,b):
            x,y=first(a).get('nativeClock'),first(b).get('nativeClock')
            return (y-x)*1000 if x is not None and y is not None and y>=x else None
        chunks=defaultdict(list)
        for f in fields:
            if all(k in f for k in ['bridgeID','request','chunkID']):chunks[(f['bridgeID'],f['request'],f['chunkID'])].append(f)
        reads=[]
        for key,observations in sorted(chunks.items()):
            def stage(n):return next((f for f in observations if f.get('phase')==n),{})
            work=stage(41) or stage(42) or stage(43)
            selected=stage(40)
            issued=stage(20) or stage(24)
            used,byte_count=work.get('usedCacheBytes'),work.get('bytes')
            def call_summary(starts,ends):
                begin={(v.get('session'),v.get('sourceCallID')):v for v in observations if v['phase'] in starts}
                finish={(v.get('session'),v.get('sourceCallID')):v for v in observations if v['phase'] in ends}
                matched=[v for v in finish.values() if v.get('startedAt') is not None and v.get('finishedAt') is not None]
                calls=[]
                for identity in sorted(begin.keys()|finish.keys()):
                    v=finish.get(identity,begin.get(identity,{}))
                    calls.append({'session':identity[0],'call':identity[1],
                        'range':[v.get('rangeLower'),v.get('rangeUpper')],
                        'startedAt':v.get('startedAt'),'finishedAt':v.get('finishedAt'),
                        'startObserved':identity in begin,'completion':PHASES.get(v.get('phase')) if identity in finish else None,
                        'bytes':v.get('bytes')})
                return {'returnedOrFailed':len(finish),'matchedStarts':len(begin.keys() & finish.keys()),'openStarts':len(begin.keys()-finish.keys()),'sumMS':sum((v['finishedAt']-v['startedAt'])*1000 for v in matched),'completeDurations':len(matched),'calls':calls}
            source=call_summary([30],[31,32]);smb=call_summary([50],[51,52])
            classification='unknown'
            if work.get('phase')==41 and used is not None and byte_count is not None and 0<=used<=byte_count:
                if used==byte_count and byte_count>0:classification='full_wrapper_cache'
                elif used>0:classification='mixed_cache_and_smb_api' if smb['returnedOrFailed'] else 'partial_cache_other_source_unresolved'
                elif smb['returnedOrFailed']:classification='smb_api_observed_zero_wrapper_cache'
                else:classification='zero_wrapper_cache_source_unresolved'
            def delta(x,y):return (y-x)*1000 if x is not None and y is not None and y>=x else None
            reads.append({'bridge':key[0],'request':key[1],'chunk':key[2],
                'readSeekEpoch':(issued or work).get('readSeekEpoch'),
                'differentReadEpoch':any(v.get('readSeekEpoch')!=v.get('epoch') for v in observations if 'readSeekEpoch' in v),
                'range':[issued.get('rangeLower',selected.get('rangeLower')),issued.get('rangeUpper',selected.get('rangeUpper'))],
                'classification':classification,'bytes':byte_count,'usedCacheBytes':used,
                'cacheGeometry':{k:v for k,v in selected.items() if k.startswith('cache')},
                'cacheSpans':[[v.get('rangeLower'),v.get('rangeUpper')] for v in observations if v['phase']==45],
                'queueWaitMS':delta(work.get('queuedAt'),work.get('startedAt')),
                'wrapperElapsedMS':delta(work.get('queuedAt'),work.get('finishedAt')),
                'sourceCalls':source,'smbLibraryCalls':smb,
                'bridgeResponseObserved':bool(stage(22)),'bridgeFailureObserved':bool(stage(23)),
                'bridgeStartedAt':stage(20).get('nativeClock'),'bridgeRespondedAt':stage(22).get('nativeClock'),
                'respondedBytes':stage(22).get('bytes'),
                'wrapperOutcome':PHASES.get(work.get('phase'))})
        issued_at=first(2).get('nativeClock')
        candidates=[r for r in reads if issued_at is not None and r['bridgeStartedAt'] is not None
            and r['bridgeRespondedAt'] is not None and r['bridgeStartedAt']>=issued_at
            and r['readSeekEpoch']==first(1).get('epoch') and not r['differentReadEpoch']]
        earliest=min(candidates,key=lambda r:r['bridgeRespondedAt'],default=None)
        first_response=({k:earliest[k] for k in ['bridge','request','chunk','range','respondedBytes','bridgeStartedAt','bridgeRespondedAt']}
            | {'seekIssuedToResponseMS':(earliest['bridgeRespondedAt']-issued_at)*1000,
               'responseToFirstFrameDeliveryMS':(first(7)['nativeClock']-earliest['bridgeRespondedAt'])*1000 if 'nativeClock' in first(7) else None}) if earliest else None
        bounds=[1,2,3,4,5,6,7,8,9]
        first_seq,last_seq=rows[0]['sequence'],rows[-1]['sequence']
        result.append({'run':run,'trace':trace,'epoch':first(1).get('epoch',fields[0].get('epoch')),
            'target':first(1).get('seekTarget'),'rate':first(2).get('rate'),
            'terminalReason':first(9).get('detail'), 'missingBoundaries':[PHASES[p] for p in bounds if not first(p)],
            'entryToSeekMS':elapsed(1,2),'seekAwaitMS':elapsed(2,3),
            'earlyPlayCommands':[v for v in fields if v['phase']==12],
            'seekIssuedToEarlyPlayMS':elapsed(2,12),'seekIssuedToCallbackMS':elapsed(2,13),
            'callbackToAwaitResumeMS':elapsed(13,3),'earlyPlayToDeliveryMS':elapsed(12,7),
            'pendingOutputProbe':first(14),'pendingOutputAvailableUnqualified':first(15),
            'firstDeliveryPlayerTime':first(7).get('playerTime'),'firstDeliveryQueryPTS':first(7).get('queryPTS'),
            'seekReturnToAvailableMS':elapsed(3,4),'entryToDeliveryMS':elapsed(1,7),
            'deliveryToPresentationNoticeMS':elapsed(7,8),
            'firstDeliveredPTS':first(7).get('framePTS'),
            'copyForFirstDeliveredFrameMS':((first(7)['finishedAt']-first(7)['startedAt'])*1000 if 'finishedAt' in first(7) and 'startedAt' in first(7) else None),
            'closingState':{k:first(10).get(k) for k in ['active','pending','worker']},
            'detailSuppressed':max(v.get('diagnosticSuppressed',0) for v in fields),
            'writerDroppedObserved':max(r.get('dropped',0) for r in rows),
            'writerFailuresObserved':max(r.get('writerFailures',0) for r in rows),
            'sequenceGapsInsideEvent':[g for g in gaps[run] if g[0]<=last_seq and g[1]>=first_seq],
            'firstSameEpochChunkResponse':first_response,'chunkLimitChanges':[v for v in fields if v['phase']==11],
            'linkedChunks':len(reads),'unlinkedDetailRows':sum(v['phase']>=20 and 'chunkID' not in v for v in fields),'reads':reads})
    return {'boundaryNotice':'AVPlayer seek-await and output-copy/delivery observations; no compressed-frame submit or hardware decoder callback. Source and SMB sums overlap, never add them as wall time. Initial/final missing records, detail suppression and writer counters limit completeness. SMB API return is not wire packet timing.','events':result}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('directory',type=Path);args=parser.parse_args()
    records=[];errors=[]
    for path in sorted(args.directory.glob('*.jsonl')):
        for number,line in enumerate(path.read_bytes().splitlines(),1):
            try:records.append(json.loads(line))
            except (ValueError,UnicodeDecodeError):errors.append({'file':path.name,'line':number})
    output=analyze(records);output['invalidLines']=errors
    print(json.dumps(output,indent=2,ensure_ascii=False))
if __name__=='__main__':main()
