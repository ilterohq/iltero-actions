# Examples

| Workflow | Use | Iltero account |
| --- | --- | --- |
| [`preview.yml`](preview.yml) | Check each pull request: plan every unit with no credentials and check each plan. A second job posts the result as a comment on the pull request. | Not needed |
| [`deploy.yml`](deploy.yml) | Deploy on push with no Iltero account: check each unit's plan, apply it, record the deployment, then pack and check each record. | Not needed |
| [`greenfield.yml`](greenfield.yml) | Deploy each environment on push, in a governed run on Iltero Platform: plan, check, approval check, apply and record each unit, then close the run. | Needed |

Replace every `0000000000000000000000000000000000000000` with the commit of the iltero-actions release you use, and
the example values (role ARNs, region, branches) with your own. A workflow that needs no account works with a
`.iltero/config.yml` that has no `platform` section.
