# Full runtime validation (Zod analog) is a non-goal; form validation only

ash_typescript generates Zod schemas for runtime type checking and form validation, because TypeScript's types are erased at runtime and JSON from the server is otherwise unchecked. Swift doesn't share that problem: types are preserved at runtime and `Codable` already validates structure and types at the decode boundary, so a value that decodes is already shape-checked. Generating a parallel "Zod for Swift" schema system would therefore be mostly redundant.

We reduce this feature to **client-side form-validation functions** (M3) — validating user input against an action's accepted arguments before sending — and treat full runtime-schema generation as a **non-goal** unless the dogfood app surfaces a concrete need. This is a deliberate deviation from ash_typescript's feature set, driven by the idiomatic-Swift principle (ADR-0002).
