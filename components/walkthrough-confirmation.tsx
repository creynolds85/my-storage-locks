import {Check} from 'lucide-react';

/** Decorative only: mounted after persistence, removed before the next unit appears. */
export default function WalkthroughConfirmation({compact=false}:{compact?:boolean}){
 return <span className={'walk-confirmation-effect'+(compact?' compact':'')} aria-hidden="true">
  <svg className="walk-border-sweep" width="100%" height="100%" focusable="false"><rect x="1.5" y="1.5" width="100%" height="100%" rx="10" pathLength="100"/></svg>
  <span className="walk-confirmation-mark"><Check size={compact?30:64} strokeWidth={4}/></span>
 </span>;
}
