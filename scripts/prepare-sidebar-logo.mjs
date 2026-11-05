import fs from 'node:fs/promises';
// Reuse the approved transparent raster. Clips isolate its existing blue and
// charcoal components without tracing, redrawing, or changing any geometry.
const source = await fs.readFile('public/brand/logo-transparent.png');
const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="50 87 1450 474" role="img" aria-label="My Storage Locks">
<defs><image id="approved" width="1536" height="691" href="data:image/png;base64,${source.toString('base64')}"/>
<clipPath id="blue"><path d="M640 87H900V254H640Z M50 280H575V320H50Z M963 280H1500V320H963Z M50 476H575V518H50Z M963 476H1500V518H963Z M999 338H1500V465H999Z"/></clipPath>
<clipPath id="charcoal"><path d="M50 335H998V465H50Z M575 253H963V557H575Z"/></clipPath>
<filter id="white" color-interpolation-filters="sRGB"><feColorMatrix type="matrix" values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 1 0"/></filter></defs>
<use href="#approved" clip-path="url(#blue)"/>
<g clip-path="url(#charcoal)"><use href="#approved" filter="url(#white)"/></g></svg>`;
await fs.writeFile('public/brand/logo-sidebar-dark.svg', svg);
console.log('Sidebar logo derived from approved artwork; original assets unchanged.');
