# Vendored JavaScript tools

Used by `languages/javascript/` (the daemon and the instrumenter), so that a
classroom computer needs nothing but Node.js 18+. They are never imported by
student code or by the worker that runs it.

| Package | Version | Source | Used for |
| --- | --- | --- | --- |
| acorn | 8.19.0 | github.com/acornjs/acorn (`acorn/src`) | parsing, contract checks, checkpoints |
| acorn-walk | 8.3.5 | github.com/acornjs/acorn (`acorn-walk/src`) | walking the syntax tree |
| eslint-scope | 9.1.2 | github.com/eslint/js (`packages/eslint-scope/lib`) | undefined names when building |
| esrecurse | 4.3.0 | github.com/estools/esrecurse | dependency of eslint-scope |
| estraverse | 5.3.0 | github.com/estools/estraverse | dependency of eslint-scope |
| js-beautify | 2.0.3 | github.com/beautifier/js-beautify (`js/src/core`, `js/src/javascript`) | Format button |

Each directory holds the package's source files at the release tag (no build
step was needed) and a minimal `package.json`. The only changes: eslint-scope
and esrecurse import their dependencies by relative path
(`../estraverse/estraverse.js`, `../esrecurse/esrecurse.js`), because there is
no `node_modules` directory. The licenses are in `LICENSES/`; esrecurse
carries its BSD license in the header of `esrecurse.js`.

prettier is not vendored: it cannot be built from its sources without npm.
