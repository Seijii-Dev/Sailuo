import {ApiError,gh,type Context} from './api';
import {portmapEndpointReady} from "./access-options-client";
export {portmapEndpointReady} from "./access-options-client";
export async function hasPortmapSecret(c:Context):Promise<boolean>{try{await gh(c,'/actions/secrets/PORTMAP_OVPN_CONFIG');return true;}catch(e){if(e instanceof ApiError&&e.status===404)return false;throw e;}}
export async function requirePortmapConfiguration(c:Context,inputs:Record<string,string>){if(inputs.access!=='portmap')return;if(!portmapEndpointReady(inputs))throw new ApiError(400,'Enter the public hostname and port before selecting Portmap');if(!await hasPortmapSecret(c))throw new ApiError(400,'Save PORTMAP_OVPN_CONFIG in GitHub Secrets before selecting Portmap');}
