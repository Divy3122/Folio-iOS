# Folio — Team Responsibilities

| Member | GitHub Username | Branch |
|---|---|---|
| Receipt Scanner & AI | Divy3122 | feature/receipt-scanner |
| Return Reminders | BrandonH-12 | feature/return-reminders |
| Receipt Storage | zoinks-05 | feature/receipt-storage |
| Spending Dashboard | Unassigned | feature/spending-dashboard |
| Architecture & Integration | Unassigned | feature/app-integration |

## Git Workflow

- main: Stable, tested application
- develop: Shared integration branch
- feature/*: Individual development branches

Each member works on their assigned feature branch.

All feature changes must be reviewed and merged into develop
through pull requests.

Only tested, stable releases are merged into main.


## Shared foundation boundaries

The assignments above are unchanged. Receipt Storage owns `Features/ReceiptLibrary`; scanner, dashboard and reminders use their corresponding feature folders. Architecture & Integration coordinates App/Core and shared Domain/Data contracts. Propose shared contract changes through a PR and notify affected owners. Unassigned roles remain unassigned until the team agrees otherwise.

See [architecture](ARCHITECTURE.md) for service contracts and [contributing](../CONTRIBUTING.md) for branch setup. Each feature branch should merge the latest `origin/develop` before starting work; preserve existing commits and use PRs back to develop.
