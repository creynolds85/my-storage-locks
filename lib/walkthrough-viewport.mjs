/** Visible layout-viewport coordinates; the nav rectangle already includes its safe area. */
/** @param {{sectionTop:number,viewportTop?:number,viewportHeight:number,navTop?:number|null}} values */
export function quickWalkHeight({sectionTop,viewportTop=0,viewportHeight,navTop=null}){const bottom=viewportTop+viewportHeight;return Math.max(0,Math.floor(Math.min(bottom,navTop===null?bottom:navTop)-Math.max(viewportTop,sectionTop)-8))}
