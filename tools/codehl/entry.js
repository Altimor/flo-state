// Code-block / HTML highlighting for Flo State Native, run in JavaScriptCore.
// Uses the exact parsers the web editor uses (@codemirror/language-data for
// fenced code, lang-html (matchClosingTags: false) for HTML in markdown) and
// the prosemark HighlightStyles' tag rules, resolved to style descriptors.
import { languages } from "@codemirror/language-data";
import { LanguageDescription } from "@codemirror/language";
import { html } from "@codemirror/lang-html";
import { parser as yamlParser } from "@lezer/yaml";
import { highlightTree, tagHighlighter, tags as t } from "@lezer/highlight";

// [color, fontWeight, fontStyle, fontSize(em), textDecoration, opacity, mono]
const S = (o) => o;
const base = [
  [t.heading1, S({ size: 1.6, weight: 700 })], [t.heading2, S({ size: 1.4, weight: 700 })],
  [t.heading3, S({ size: 1.2, weight: 700 })], [t.heading4, S({ weight: 700 })],
  [t.heading5, S({ weight: 700 })], [t.heading6, S({ weight: 700 })],
  [t.strong, S({ weight: 700 })], [t.emphasis, S({ italic: true })],
  [t.strikethrough, S({ strike: true, color: "muted" })], [t.meta, S({ color: "muted" })],
  [t.comment, S({ color: "muted" })],
];
const general = [
  [t.link, S({ color: "link" })], [t.keyword, S({ color: "keyword" })],
  [[t.atom, t.bool, t.url, t.contentSeparator, t.labelName], S({ color: "atom" })],
  [[t.literal, t.inserted], S({ color: "literal" })], [[t.string, t.deleted], S({ color: "string" })],
  [[t.regexp, t.special(t.string)], S({ color: "regexp" })], [t.escape, S({ color: "inherit" })],
  [t.definition(t.variableName), S({ color: "definitionVariable" })],
  [t.local(t.variableName), S({ color: "localVariable" })],
  [[t.typeName, t.namespace], S({ color: "typeNamespace" })], [t.className, S({ color: "className" })],
  [[t.special(t.variableName), t.macroName], S({ color: "specialVariable" })],
  [t.definition(t.propertyName), S({ color: "definitionProperty" })],
  [t.comment, S({ color: "muted" })], [t.invalid, S({ color: "invalid" })],
];
const app = [
  [t.strong, S({ weight: 600 })], [t.heading, S({ weight: 600 })],
  [t.heading1, S({ weight: 600 })], [t.heading2, S({ weight: 600 })], [t.heading3, S({ weight: 600 })],
  [t.heading4, S({ weight: 600 })], [t.heading5, S({ weight: 600 })], [t.heading6, S({ weight: 600 })],
];
// one tagHighlighter per HighlightStyle; class "hN" = global rule index (stylesheet order)
const rules = [];
const highlighters = [base, general, app].map((spec) => tagHighlighter(spec.map(([tag, style]) => {
  rules.push(style);
  return { tag, class: "h" + (rules.length - 1) };
})));

const htmlParser = html({ matchClosingTags: false }).language.parser;

function findParser(info) {
  if (!info) return null;
  info = /\S*/.exec(info)[0];
  const found = LanguageDescription.matchLanguageName(languages, info, true);
  if (!found) return null;
  if (found.support) return found.support.language.parser;
  found.load();          // resolves in a microtask; the caller asks again
  return "loading";
}

// ranges: [[from, to], ...] relative to `text`. Returns flat
// [from, to, ruleIndex, ruleIndex, ..., -1, ...] (-1 terminates each span).
globalThis.floHighlight = function (kind, info, text, ranges) {
  const parser = kind === "html" ? htmlParser : kind === "yaml" ? yamlParser : findParser(info);
  if (parser === "loading") return "loading";
  if (!parser) return null;
  const tree = parser.parse(text, [], ranges.map(([from, to]) => ({ from, to })));
  const out = [];
  let rs = ranges;
  highlightTree(tree, highlighters, (from, to, cls) => {
    out.push(from, to);
    for (const c of cls.split(" ")) if (c) out.push(+c.slice(1));
    out.push(-1);
  }, rs[0][0], rs[rs.length - 1][1]);
  return out;
};
globalThis.floHighlightRules = rules;
globalThis.floLanguageNames = languages.map((l) => [l.name, l.alias, l.extensions]);
