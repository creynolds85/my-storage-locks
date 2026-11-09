import type {ReactNode} from 'react';
export default function PublicLegalPage({title,children}:{title:string;children:ReactNode}){
 return <main className="tenant-page"><header className="tenant-header"><a href="/get-combination" aria-label="My Storage Locks"><img src="/brand/logo-sidebar-dark.svg" alt="My Storage Locks" width="220" height="72"/></a></header><article className="tenant-card legal-card"><h1>{title}</h1><p className="legal-date">Effective November 8, 2026</p>{children}<p><a href="/get-combination">Request a combination or contact your facility</a></p></article><footer className="tenant-footer"><nav aria-label="Legal"><a href="/privacy">Privacy Policy</a> · <a href="/terms">SMS Terms and Conditions</a></nav>My Storage Locks</footer></main>;
}
