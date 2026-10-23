"use client";
import {createContext,useContext} from "react";
// The dashboard ships in English only. `T` and `t` are kept as identity helpers so
// components can render plain strings without a translation lookup.
const Context=createContext<{locale:"en";choose:(value:"en")=>void}>({locale:"en",choose:()=>{}});
export function translate(text:string){return text}
export function useLocale(){const c=useContext(Context);return {...c,t:(text:string)=>text}}
export function T({text}:{text:unknown}){return typeof text==='string'?text:text as React.ReactNode}
export default function LocaleProvider({children}:{children:React.ReactNode}){return <Context.Provider value={{locale:"en",choose:()=>{}}}>{children}</Context.Provider>}
export function confirmLocalized(message:string){return window.confirm(message)}
