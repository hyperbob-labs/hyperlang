# Security Policy

## Reporting a vulnerability

Report suspected vulnerabilities privately to `bob@hyperbob.ai`. Do not open a
public issue.

Include the Hyperlang version, the OTP and Elixir versions, a minimal guest
source and manifest that reproduces the problem, and the observed and
expected behavior.

## Scope

The security contract is `doc/SECURITY_SPECIFICATION.md`. It defines what
Hyperlang guarantees, the threat model, and the known limitations. Hyperlang
alone is suitable for trusted or cooperative guest code. Semi-trusted or
hostile multi-tenant code needs host quotas plus OS or node isolation.
