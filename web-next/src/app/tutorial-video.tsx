"use client";
import {T} from "@/app/locale-provider";

import {useEffect,useRef,useState} from "react";
export default function TutorialVideo({src,poster}:{src?:string;poster?:string}){
 const video=useRef<HTMLVideoElement>(null),[playing,setPlaying]=useState(false),[failed,setFailed]=useState(false);
 useEffect(()=>{const el=video.current;if(!src||!el)return;el.muted=true;
  // Respect the device accessibility preference; browsers may also block autoplay.
  if(window.matchMedia('(prefers-reduced-motion: reduce)').matches)return;
  el.play().catch(()=>setPlaying(false));
 },[src]);
 return <section className="tutorial-section" aria-labelledby="tutorial-heading"><div className="tutorial-heading"><span className="eyebrow"><T text={"Guide singkat"}/></span><h2 id="tutorial-heading"><T text={"Lihat caranya, ikuti langkahnya."}/></h2><p><T text={"From membuat repo hingga menghubungkan XyDesk. Video diputar without suara."}/></p></div>{src&&!failed?<div className="tutorial-player"><video ref={video} src={src} poster={poster} muted loop playsInline preload="metavailableta" aria-label="Video guide useran RdpFree without suara" onPlay={()=>setPlaying(true)} onPause={()=>setPlaying(false)} onError={()=>{setFailed(true);setPlaying(false)}}/><button className="secondary small tutorial-toggle" onClick={()=>{const el=video.current;if(!el)return;if(el.paused){el.muted=true;el.play().catch(()=>setPlaying(false))}else el.pause()}}><T text={playing?'Jeda video':'Putar video'}/></button></div>:<div className="tutorial-placeholder"><svg viewBox="0 0 48 48" width="48" height="48" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true"><rect x="5" y="9" width="38" height="30" rx="7"/><path d="m20 17 12 7-12 7Z"/></svg><strong><T text={failed?'Video not yet dapat diputar':'Video guide segera hadir'}/></strong><p><T text={failed?'Coba muat ulang page. Guide tertulis di bawah tetap can digunwill.':'Sambil menunggu, ikuti guide tertulis di bawah.'}/></p></div>}</section>
}
