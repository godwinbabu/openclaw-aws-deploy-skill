# Contributing

Thanks for your interest in improving openclaw-aws-deploy! Here's how to contribute.

## Getting Started

1. **Fork** the repo
2. **Clone** your fork locally
3. **Create a branch** from `main`: `git checkout -b your-name/short-description`
4. **Make your changes** — keep commits focused and atomic
5. **Test** your changes with a real deployment if possible
6. **Push** and open a **Pull Request** against `main`

## Pull Request Guidelines

- PRs require **1 approving review** before merge
- All conversations must be resolved before merge
- Stale approvals are dismissed on new pushes
- Squash merge only (keeps history clean)
- Delete your branch after merge

## What We're Looking For

- Bug fixes (especially deployment edge cases on different AWS regions/accounts)
- Documentation improvements
- New troubleshooting entries (real issues you hit — add to `references/TROUBLESHOOTING.md`)
- Security hardening
- Support for additional channels or model providers

## What We Won't Merge

- Changes that open inbound ports or weaken security posture
- Hardcoded credentials or secrets (even in examples — use `_PLACEHOLDER` suffix)
- Features that require elevated IAM permissions without justification
- Cosmetic-only changes with no functional impact

## Reporting Issues

Open a GitHub issue with:
- What you expected vs. what happened
- AWS region and instance type
- Relevant error output (redact any account IDs or secrets)

## Security Vulnerabilities

If you find a security issue, **do not open a public issue**. Email the maintainer directly or use GitHub's private vulnerability reporting.

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
