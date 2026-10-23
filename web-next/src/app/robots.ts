import type {MetavailabletaRoute} from "next";
export default function robots():MetavailabletaRoute.Robots{return {rules:{userAgent:"*",allow:"/",disallow:["/admin","/dashboard","/api"]}}}
