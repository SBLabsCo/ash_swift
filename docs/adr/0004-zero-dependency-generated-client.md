# Zero-dependency generated client: async/await + Codable + URLSession

The generated Swift client and its runtime support library (AshSwiftRuntime) take **no third-party dependencies**. Concrete choices:

- **Concurrency:** Swift Concurrency (`async`/`await`); errors surface via `throws` and a typed error enum. (Rejected: completion handlers / Combine — legacy.)
- **Serialization:** `Codable` (Foundation).
- **HTTP:** `URLSession` (Foundation) as the default transport, behind a **pluggable transport protocol** so callers who standardize on Alamofire (or need interceptors/custom request options — AshTypescript's "custom fetch" analog) can inject their own implementation. The default requires nothing to install.
- **Runtime split:** a small hand-written `AshSwiftRuntime` package holds the base client (request encoding, endpoint POST, error decoding, hook dispatch, config: base URL, headers, tenant). Generated per-resource code stays thin — typed signatures + Codable models over that runtime. Mirrors how ash_typescript separates a static runtime from generated functions.
- **Transport scope:** HTTP only for v1. Phoenix Channels (real-time) is a separable later milestone requiring a WebSocket/Phoenix-channel Swift client.

Rationale: staying dependency-free keeps adoption frictionless and avoids lock-in, while the pluggable transport still gives Alamofire users a path — we get both a clean default and extensibility without forcing a dependency on anyone.
