# Contributing

Work from a short-lived typed branch such as `feat/short-topic`, `fix/short-topic`, `docs/short-topic`, or `chore/short-topic`. Keep each branch and pull request bounded to one reviewable outcome. There is no develop branch; pull requests target `main`.

Use focused vertical TDD: add a focused test, observe the expected failure, implement the smallest scoped change, and observe it pass. Before review, run the relevant focused tests plus the full macOS CI commands. CI must pass on the pull request.

Every pull request needs independent review of the exact tree that will merge. The author must preserve pending release, deployment, and acceptance states truthfully; tests do not substitute for native interaction acceptance.

After approval, squash the pull request into `main` and delete the typed branch. This repository workflow is a contributor contract and does not claim server-side branch protection or any particular hosting setting.
