import sharp from 'sharp';
import fs from 'node:fs/promises';
import path from 'node:path';

const out = path.resolve('public/brand');
const original = path.join(out, 'approved-original.jpg');
await fs.mkdir(out, { recursive: true });
// Only background pixels change. Keep the approved colored artwork in place.
const {data, info} = await sharp(original).ensureAlpha().raw().toBuffer({resolveWithObject:true});
for(let i=0;i<data.length;i+=4){
  const white = Math.min(data[i],data[i+1],data[i+2]);
  data[i+3] = white >= 250 ? 0 : white <= 230 ? 255 : Math.round((250-white)/20*255);
}
const transparent = sharp(data,{raw:{width:info.width,height:info.height,channels:4}});
await transparent.clone().png().toFile(path.join(out,'logo-transparent.png'));
const bounds={left:50,top:87,width:1450,height:474};
await sharp(original).extract(bounds).png().toFile(path.join(out,'logo-horizontal.png'));
await transparent.clone().extract(bounds).resize({width:3072}).png().toFile(path.join(out,'logo-high-resolution.png'));
await sharp(original).extract(bounds).resize({width:600}).png().toFile(path.join(out,'logo-header.png'));
const png=await fs.readFile(original);
await fs.writeFile(path.join(out,'logo-horizontal.svg'),`<svg xmlns="http://www.w3.org/2000/svg" viewBox="50 87 1450 474" role="img" aria-label="My Storage Locks"><image width="1536" height="691" href="data:image/jpeg;base64,${png.toString('base64')}"/></svg>`);
// Faithful compact extraction: same shackle and body proportions, without the wordmark.
const icon=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="545 66 445 516"><path fill="#0198F4" d="M649 247V222C649 156 702 103 768 103S886 156 886 222V247H842V222C842 180 809 145 768 145S693 180 693 222V247Z"/><path fill="#6B6E73" fill-rule="evenodd" d="M637 261H898A54 54 0 0 1 952 315V491A54 54 0 0 1 898 545H637A54 54 0 0 1 583 491V315A54 54 0 0 1 637 261ZM637 297A16 16 0 0 0 621 313V494A16 16 0 0 0 637 510H898A16 16 0 0 0 914 494V313A16 16 0 0 0 898 297Z"/></svg>`;
await fs.writeFile(path.join(out,'padlock.svg'),icon);
await fs.writeFile('public/favicon.svg',icon);
for(const [file,size] of [['favicon-32.png',32],['apple-touch-icon.png',180],['icon-192.png',192],['icon-512.png',512]]){
  await sharp(Buffer.from(icon)).resize(size,size,{fit:'contain',background:'#ffffff'}).png().toFile(path.join('public',file));
}
await fs.writeFile(path.join(out,'README.md'),`# Approved My Storage Locks assets\n\nThe supplied 1536 × 691 raster is retained byte-for-byte as approved-original.jpg. The deployed horizontal and header PNGs are cropped/resized copies of that source; typography, wordmark, line weights, and colors are preserved. The transparent PNG removes only the near-white background and preserves colored source pixels. The 3072px PNG is a source-derived enlargement, not newly invented detail. The full-logo SVG embeds the approved raster so its letterforms remain exact; it is not a fully vectorized wordmark. The compact padlock SVG follows the source's visible geometry and closes the body outline behind the omitted lettering, without adding a keyhole.\n`);
console.log('Approved-source logo assets and compact icons prepared.');
