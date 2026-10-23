import {ApiError,Context,gh} from "./api";
import {db} from "./db";
export const choices:Record<string,string[]>={duration_minutes:["15","30","60","120","180","240","300","330","360"],access:["tailscale","portmap"],runner:["windows-2022","windows-2025","windows-latest"],microphone:["yes","no"],storage_boost:["yes","no"],debloat:["light","full","none"],windows10:["yes","no"],xydesk:["yes","no"],extras:["yes","no"]};
export const defaults:Record<string,string>={duration_minutes:"360",hostname:"rdpfree",rdp_user:"xyadmin",access:"tailscale",portmap_host:"",portmap_port:"",runner:"windows-2022",microphone:"yes",storage_boost:"no",debloat:"light",windows10:"no",xydesk:"yes",extras:"no"};
const legacyKeys=["wallpaper","wallpaper_url","gta_sa_url","samp_extra","grafis","samp","roblox","minecraft_java","minecraft_bedrock"];
export function validate(raw:Record<string,unknown>){const inputs={...defaults};for(const [k,v] of Object.entries(raw)){if(legacyKeys.includes(k))continue;if(!Object.prototype.hasOwnProperty.call(defaults,k)||typeof v!=="string")throw new ApiError(400,"Unknown parameter: "+k);inputs[k]=v;}
 for(const [k,allowed] of Object.entries(choices))if(!allowed.includes(inputs[k]))throw new ApiError(400,"Invalid option: "+k);
 if(!/^[a-zA-Z0-9][a-zA-Z0-9-]{0,29}$/.test(inputs.hostname))throw new ApiError(400,"Hostname must be 1-30 letters, digits, or hyphens");
 if(!/^[a-zA-Z][a-zA-Z0-9_-]{2,19}$/.test(inputs.rdp_user)||/^(admthisstrator|guest|defaultaccount|wdagutilityaccount|system|localservice|networkservice|con|prn|aux|nul)$/i.test(inputs.rdp_user))throw new ApiError(400,"Invalid RDP username");
 if(inputs.portmap_host&&!/^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$/.test(inputs.portmap_host))throw new ApiError(400,"Invalid Portmap hostname; do not include tcp:// or a port");
 if(inputs.portmap_port&&(!/^\d{1,5}$/.test(inputs.portmap_port)||Number(inputs.portmap_port)<1||Number(inputs.portmap_port)>65535))throw new ApiError(400,"Public port must be 1-65535");
 return inputs;}
export function migrateSettings(raw:Record<string,unknown>){
 const migrated:Record<string,unknown>={...raw};
 // Drop settings that belonged to removed features, then rename the legacy Indonesian keys.
 for(const k of [...legacyKeys,"tunnel_provider"])delete migrated[k];
 const rename:Record<string,string>={durasi_menit:"duration_minutes",access:"access",win10:"windows10",ekstra:"extras",perpanjang_otomatis:"auto_renew"};
 for(const [from,to] of Object.entries(rename))if(from in migrated){if(!(to in migrated))migrated[to]=migrated[from];delete migrated[from];}
 // Normalize the old Indonesian option values to their English equivalents.
 const values:Record<string,string>={ya:"yes",no:"no",off:"no",on:"yes",ringan:"light",none:"none"};
 for(const key of ["microphone","storage_boost","windows10","xydesk","extras"])if(typeof migrated[key]==="string"){const v=String(migrated[key]).trim().toLowerCase();migrated[key]=values[v]??v;}
 if(typeof migrated.debloat==="string"){const v=migrated.debloat.trim().toLowerCase();migrated.debloat=v==="ringan"?"light":v==="no"?"none":v;}
 if(migrated.access!=="portmap")migrated.access="tailscale";
 // Legacy runner labels are migrated to the real default image; no workflow starts on save.
 if(!("runner" in migrated)||["github","self-hosted"].includes(String(migrated.runner)))migrated.runner="windows-2022";
 return validate(migrated);}
export async function loadSettings(repo:string){const r=await db().prepare("SELECT inputs FROM settings WHERE repo=?").bind(repo).first<{inputs:string}>();return r?migrateSettings(JSON.parse(r.inputs)):{...defaults};}
export type Run={id:number;run_attempt?:number;status:string;conclusion:string|null;created_at:string;run_started_at:string;html_url:string;name:string;workflow_id:number};
export async function runs(ctx:Context){return (await gh<{workflow_runs:Run[]}>(ctx,"/actions/workflows/rdp-6h.yml/runs?per_page=30")).workflow_runs;}
export const active=(r:Run)=>["queued","in_progress","waiting","requested","pending"].includes(r.status);
