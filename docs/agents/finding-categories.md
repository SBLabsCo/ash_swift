# Finding categories

The vocabulary for the `category` that every pre-PR review finding carries. The `reviewer`, `refactorer`, `architect` and `security` agents emit it, and it is part of the `v` 2 run record ([ship-ticket.md](ship-ticket.md#contracts)). `bin/findings-retro` groups findings by category across merged PRs. The `findings-retro` skill then turns a category that keeps recurring into a line of guidance the implementer reads, so the same mistake stops reaching review.

**How to pick one.** A category names the *kind* of mistake an implementer made, the thing a checklist line would have prevented. It never names the feature or file: `ir-decision-split`, not `destroy-input-struct`. Use the slug below that fits. Coin a new kebab-case slug only when none does, and make it general enough that the same mistake in another part of the pipeline would get it too. A near-synonym of an existing slug splits one recurring mistake into two that each look rare, which is the one way to make the retro miss it. The retro proposes merging slugs that drift apart, and adds the ones that earn a place here.

The list was seeded on 2026-11-15 by categorising the 49 pre-PR findings on PRs #93–#119 (every ship-ticket run since the loop was ported in #92), plus the review Action's findings on #86, #88 and #90, which predate the loop and carry no run record.

| Category | Usually raised by | The mistake |
|---|---|---|
| `adr-deviation` | reviewer, architect | Code goes around a settled ADR without recording why (e.g. reading `Ash.Resource.Info` where ADR-0009 says the manifest is the source). |
| `breaking-change-undeclared` | reviewer | A change to generated Swift or a public runtime API isn't flagged as breaking: no `!`/`BREAKING CHANGE:` in the commit, or no CHANGELOG note a consumer can actually reach on Hex/HexDocs. |
| `brittle-test` | refactorer | A test depends on incidental state: shared files accumulating in one target, parsing compiler output by regex, a hardcoded key list that misses later keys. |
| `dead-code` | refactorer | The diff leaves code it made unnecessary: an unused parameter, a cleanup with nothing to clean, a hardcoded name the helper already owns. |
| `doc-formatting-drift` | refactorer | Reworded docs aren't reflowed to the file's wrap width, so the next edit starts with a ragged diff. |
| `duplicated-code` | refactorer | Library code is copy-pasted (a naming convention rebuilt in two clauses) instead of shared, so a rename must hit every copy. |
| `duplicated-test-harness` | refactorer | Test setup, a temp-dir fixture, a stub transport or a Swift test harness is rebuilt next to one that already exists, instead of reusing or extracting it. |
| `glossary-drift` | architect, refactorer | Code or docs misuse a CONTEXT.md term, or give one word two meanings in the same module (e.g. "lookup" for both the get_by values and the whole get request). |
| `ir-decision-split` | architect, refactorer | One decision in the Reader → IR → Emitter pipeline is made in two places, or two consumers of one IR key (Emitter, Contract) decide it differently, so they can drift. |
| `misleading-test-structure` | refactorer, reviewer | A test's name, `describe`/`MARK` section or placement claims something its body doesn't check. |
| `redundant-test` | refactorer | A test repeats what another test already proves, so a behaviour change has a second place to edit for no extra coverage. |
| `shallow-module` | refactorer | A type, helper or function only forwards or copies fields across (it fails the deletion test), adding a layer without hiding anything. |
| `silent-fallthrough` | reviewer | A catch-all clause or merge quietly turns an unmodelled shape or a key collision into `nil` or a default, instead of raising. |
| `stale-doc-comment` | reviewer, refactorer, architect | A moduledoc, comment, README, lessons.md entry or citation states something the code no longer does, never did, or gives the wrong reason or source for it. |
| `test-at-wrong-seam` | refactorer | A Reader classification is pinned only by substring matches on rendered Swift instead of at the IR seam (ADR-0010). |
| `test-runtime-cost` | refactorer | The diff adds avoidable cost to the slow suites: a fresh SwiftPM build or `swift build` per test where one shared build would do. |
| `unhandled-edge-case` | reviewer | Logic handles the happy path but mishandles a realistic case, such as a failure midway that leaks temp dirs, or a soft destroy that still accepts attributes. |
| `untested-behaviour` | reviewer, refactorer | A new behaviour, contract or code branch has no test that would fail if it broke (e.g. a generated signature never called from the consumer package, or a body key no test sets). |
| `vacuous-test-assertion` | refactorer | An assertion cannot fail, or checks the harness rather than the behaviour (e.g. `refute` on a string the line above already excludes, `File.exists?` on a file setup always writes). |
