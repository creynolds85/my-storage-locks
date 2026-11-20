import {Check} from 'lucide-react';

/** Immediate visual feedback. Saved status is announced separately. */
export default function WalkthroughConfirmation(){
 return <span className="walk-confirmation-effect" aria-hidden="true">
  <span className="walk-confirmation-mark"><Check size={58} strokeWidth={4}/></span>
 </span>;
}
