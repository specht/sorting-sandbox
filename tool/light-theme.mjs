// Generates the light theme from the dark stylesheet:
//
//   node scripts/light-theme.mjs web/style.css web/light.css
//
// Every rule that sets a color is repeated under :root[data-theme="light"]
// with the color mirrored in lightness (in the perceptual OKLab space, so hue
// and saturation stay recognizable): dark panels become light panels, light
// text becomes dark text, and accents become deeper shades of themselves.
// Shadows stay dark but get softer. Run it again after changing style.css.
// The same script is used by all three sandboxes.
import fs from 'node:fs';

const [input, output] = process.argv.slice(2);
if (!input || !output) {
  console.error('Usage: node light-theme.mjs style.css light.css');
  process.exit(64);
}

// ---------------------------------------------------------------- colors
const srgbToLinear = c => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const linearToSrgb = c => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);

function toOklab([r, g, b]) {
  [r, g, b] = [r, g, b].map(v => srgbToLinear(v / 255));
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s];
}

function fromOklab([L, a, b]) {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
  return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s].map(v => linearToSrgb(v) * 255);
}

const inGamut = rgb => rgb.every(v => v >= -0.5 && v <= 255.5);

/** Mirrors the lightness: L 0.17 (page background) → 0.97, L 0.96 (text) → 0.22. */
function mirror(rgb) {
  const [L, a, b] = toOklab(rgb);
  const light = Math.min(0.985, Math.max(0.12, 1.13 - 0.95 * L));
  // Very light results are backgrounds: keep them calm.
  let chroma = light > 0.85 ? 0.55 : 1;
  let out = fromOklab([light, a * chroma, b * chroma]);
  while (!inGamut(out) && chroma > 0.02) { chroma *= 0.92; out = fromOklab([light, a * chroma, b * chroma]); }
  return out.map(v => Math.round(Math.min(255, Math.max(0, v))));
}

function parseColor(text) {
  let m = text.match(/^#([0-9a-f]{3,8})$/i);
  if (m) {
    let h = m[1];
    if (h.length === 3 || h.length === 4) h = [...h].map(c => c + c).join('');
    const n = [0, 2, 4].map(i => parseInt(h.slice(i, i + 2), 16));
    return { rgb: n, alpha: h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1 };
  }
  m = text.match(/^rgba?\(([^)]*)\)$/i);
  if (m) {
    const parts = m[1].split(/[\s,/]+/).filter(Boolean).map(Number);
    return { rgb: parts.slice(0, 3), alpha: parts.length > 3 ? parts[3] : 1 };
  }
  if (/^white$/i.test(text)) return { rgb: [255, 255, 255], alpha: 1 };
  if (/^black$/i.test(text)) return { rgb: [0, 0, 0], alpha: 1 };
  return null;
}

const format = ({ rgb, alpha }) => {
  const hex = rgb.map(v => v.toString(16).padStart(2, '0')).join('');
  return alpha >= 1 ? `#${hex}` : `rgba(${rgb.join(',')},${+alpha.toFixed(3)})`;
};

const COLOR = /#[0-9a-f]{3,8}\b|rgba?\([^)]*\)|(?<![-\w])(?:white|black)(?![-\w])/gi;

function transformValue(property, value) {
  if (property === 'color-scheme') return value.replace(/\bdark\b/, 'light');
  const shadow = /shadow$/.test(property);
  return value.replace(COLOR, literal => {
    const color = parseColor(literal);
    if (!color) return literal;
    if (shadow) {
      const [L] = toOklab(color.rgb);
      if (L < 0.5) return format({ rgb: [40, 56, 84], alpha: Math.min(1, color.alpha * 0.35) });
    }
    const rgb = mirror(color.rgb);
    // Translucent dark layers let the background photo through; light ones
    // need to cover more of it, or the page turns muddy.
    const opaque = color.alpha > 0.5 && color.alpha < 1 && toOklab(rgb)[0] > 0.85;
    return format({ rgb, alpha: opaque ? 1 - (1 - color.alpha) * 0.4 : color.alpha });
  });
}

// ---------------------------------------------------------------- CSS
const css = fs.readFileSync(input, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');

function prefix(selectorList) {
  return selectorList.split(',').map(s => s.trim()).filter(Boolean).map(s => {
    if (s.startsWith(':root')) return s.replace(':root', ':root[data-theme="light"]');
    if (/^html\b/.test(s)) return s.replace(/^html/, 'html[data-theme="light"]');
    return `:root[data-theme="light"] ${s}`;
  }).join(',\n');
}

/** Returns [{selector, declarations}] or [{media, rules}] for one block of CSS. */
function parseBlock(text) {
  const out = [];
  let i = 0;
  while (i < text.length) {
    const open = text.indexOf('{', i);
    if (open < 0) break;
    const head = text.slice(i, open).trim();
    let depth = 1, j = open + 1;
    while (j < text.length && depth) { if (text[j] === '{') depth++; else if (text[j] === '}') depth--; j++; }
    const body = text.slice(open + 1, j - 1);
    if (head.startsWith('@media') || head.startsWith('@supports')) out.push({ media: head, rules: parseBlock(body) });
    else if (!head.startsWith('@')) out.push({ selector: head, declarations: body });
    i = j;
  }
  return out;
}

function themed(rules, indent = '') {
  const lines = [];
  for (const rule of rules) {
    if (rule.media) {
      const inner = themed(rule.rules, `${indent}  `);
      if (inner.length) lines.push(`${indent}${rule.media}{`, ...inner, `${indent}}`);
      continue;
    }
    const declarations = [];
    for (const declaration of rule.declarations.split(';')) {
      const colon = declaration.indexOf(':');
      if (colon < 0) continue;
      const property = declaration.slice(0, colon).trim(), value = declaration.slice(colon + 1).trim();
      if (property !== 'color-scheme' && !value.match(COLOR)) continue;
      declarations.push(`${property}:${transformValue(property, value)}`);
    }
    if (declarations.length) lines.push(`${indent}${prefix(rule.selector).split('\n').join(`\n${indent}`)}{${declarations.join(';')}}`);
  }
  return lines;
}

const header = `/* Light theme, generated from ${input.split('/').pop()} by light-theme.mjs. Do not edit: run the script again. */`;
fs.writeFileSync(output, `${header}\n${themed(parseBlock(css)).join('\n')}\n`);
console.log(`${output} written`);
