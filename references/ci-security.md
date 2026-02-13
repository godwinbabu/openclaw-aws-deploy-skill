# CI + Security Guardrails

This repository enforces baseline quality gates on every PR:

1. ShellCheck + bash syntax checks for all scripts
2. CloudFormation linting via `cfn-lint`
3. Secret scanning via `gitleaks`
4. Contract dry-run checks for script presence and optional schema validation

## Expected behavior
- PR fails if shell scripts are invalid or unsafe
- PR fails if CloudFormation templates have structural/lint issues
- PR fails if potential secrets are detected

## Future enhancements
- Add IAM policy linting (Parliament / cfn-guard)
- Add OPA checks for infrastructure policy compliance
- Add ephemeral sandbox deploy test on schedule
