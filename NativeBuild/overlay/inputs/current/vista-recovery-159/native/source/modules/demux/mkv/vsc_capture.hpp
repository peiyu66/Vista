#pragma once
/* Owner thread only. Existing maps are queried with const lookups; no selector,
   range-indexing, stream seek/read or decoder operation occurs here. */
static void VSCapture(mkv::demux_sys_t &sys,mkv::matroska_segment_c &seg,
                     mkv::virtual_segment_c &virt,int64_t anchor,bool force=false)
{
 if(!sys.vsc.owner)return;
 int64_t now=vlc_tick_now();if(!force&&now-sys.vsc_last<200000)return;sys.vsc_last=now;
 vsc_snapshot out={};out.sampled=now;out.anchor=anchor;
 auto *chapter=virt.CurrentChapter();auto *edition=virt.CurrentEdition();
 uint64_t selection=1469598103934665603ULL;const mkv::mkv_track_t *video=nullptr;
 if(seg.tracks.size()>16)out.status=5;
 else for(auto&it:seg.tracks){bool selected=false;if(it.second->p_es)es_out_Control(sys.demuxer.out,ES_OUT_GET_ES_STATE,it.second->p_es,&selected);if(!selected)continue;out.selected_total++;selection=(selection^it.first)*1099511628211ULL;selection=(selection^it.second->fmt.i_codec)*1099511628211ULL;if(it.second->fmt.i_cat==VIDEO_ES){out.selected_video++;video=it.second.get();}}
 out.selected_hash=selection;
 uintptr_t key[4]={(uintptr_t)&seg,(uintptr_t)chapter,(uintptr_t)edition,(uintptr_t)selection};
 if(memcmp(key,sys.vsc_key,sizeof key)){memcpy(sys.vsc_key,key,sizeof key);sys.vsc_scope=vsc_identity();}
 out.scope=sys.vsc_scope;
 if(!out.status&&(!chapter||!edition||out.selected_video!=1||!video))out.status=1;
 if(!out.status){out.chapter_begin=chapter->i_mk_virtual_start_time;out.chapter_end=chapter->i_mk_virtual_stop_time;if(__builtin_sub_overflow(chapter->i_mk_virtual_start_time,(chapter->p_chapter?chapter->p_chapter->i_start_time:0),&out.offset))out.status=2;out.track=video->i_number;out.uid=video->vista_track_uid;
  int64_t local;if(out.status||__builtin_sub_overflow(anchor,out.offset,&local)||local<0)out.status=2;
  else {auto tr=seg.VistaSeekIndex()._tracks_seekpoints.find(video->i_number);if(tr==seg.VistaSeekIndex()._tracks_seekpoints.end()||tr->second.empty())out.status=3;
   else {const auto&p=tr->second;auto it=std::upper_bound(p.begin(),p.end(),local,[](int64_t v,const auto&p){return v<p.pts;});if(it!=p.begin())--it;if(it!=p.begin())--it;for(;it!=p.end()&&out.count<4;++it)out.points[out.count++]={it->pts,it->fpos,(int32_t)it->trust_level,0};}}
  if(!video->vista_track_uid_valid)out.status=4;
 }
 vsc_publish(sys.vsc,&out);
}
