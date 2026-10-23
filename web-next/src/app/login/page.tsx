
import {T} from "@/app/locale-provider";
import {getServerSession} from "next-auth";
import {authOptions} from "@/lib/auth";
import {redirect} from "next/navigation";
import Button from "./button";
export default async function Login({searchParams}:{searchParams:Promise<{error?:string}>}){
 if(await getServerSession(authOptions)) redirect("/dashboard");
 const {error}=await searchParams;
 return <main className="login"><span className="eyebrow">RdpFree / Account</span><h1><T text={"Selamat datang kembali."}/></h1><p><T text={"Login only for identitas. Access repository diminta terpisah setelah kamu sign in."}/></p><section className="card"><h2><T text={"Satu akun. Satu dashboard."}/></h2><p><T text={"Tahap 1: sign in with profil GitHub. Tahap 2: Install GitHub App and pilih repository that diizinkan."}/></p>{error&&<p className="error"><T text={"Login not yet succeeded. Coba lagi or check konfigurasi OAuth."}/></p>}<Button/><p className="muted"><T text="Foto and nama GitHub akun baru dapat tampil di komunitas. Kamu can menyembunyikannya kapan saja di dashboard."/></p></section><footer>Credit: KallAncrit</footer></main>
}
