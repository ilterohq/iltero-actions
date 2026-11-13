# Examples

## Infrastructure as code (IaC)

| Workflow | Use | Iltero account |
| --- | --- | --- |
| [`iac/preview.yml`](iac/preview.yml) | Check each pull request: plan every unit with no credentials and check each plan. A second job posts the result as a comment on the pull request. | Not needed |
| [`iac/deploy.yml`](iac/deploy.yml) | Deploy on push with no Iltero account: check each unit's plan, apply it, record the deployment, check the deployed resources after the apply, then pack and check each record. | Not needed |
| [`iac/governed-deploy.yml`](iac/governed-deploy.yml) | Deploy each environment on push, in a governed run on Iltero Platform: plan each unit and check its plan, run the pre-deploy stage, apply the unit and record it, check the deployed resources after the apply, then close the run. | Needed |
| [`iac/own-terraform.yml`](iac/own-terraform.yml) | Deploy on push with no Iltero account, with your own Terraform commands: after plan and after apply, a step records that stage of the unit's change on the runner, and a step between them warns when the unit's record still expects the pre-deploy stage, which needs Iltero Platform. A later step checks that the deployed resources still match what the apply left. | Not needed |
| [`iac/governed-own-terraform.yml`](iac/governed-own-terraform.yml) | Deploy on push in a governed run on Iltero Platform, with your own Terraform commands: after plan, before apply and after apply, a step records that stage of the unit's change. A later step checks that the deployed resources still match what the apply left. Each step also keeps its record in the run's artifact store. | Needed |

## Container images

| Workflow | Use | Iltero account |
| --- | --- | --- |
| [`image/build.yml`](image/build.yml) | Build a container image on push, with no Iltero account, in three jobs. The first builds the image for each CPU architecture in `IMAGE_PLATFORMS` (`linux/amd64,linux/arm64` by default), pushes it to the GitHub container registry and reads its index back. The second scans the pushed image once for each architecture, with read access to the registry only, and fails the workflow when any architecture has a vulnerability at one of the severities in `FAIL_ON_SCAN_SEVERITIES`. The third also runs when the scan failed the workflow after it kept the reports: it checks the image as advice, records it on the runner and uploads the record as a workflow artifact. | Not needed |
| [`image/deployment.yml`](image/deployment.yml) | Deploy a container image to Kubernetes, started by hand with the image's digest, with no Iltero account. Around the deployment, steps record each stage on the runner: before the deployment they check the image as advice, after it they report the deployed image, and after the rollout they check that every pod of the workload runs it. | Not needed |
| [`image/governed-build.yml`](image/governed-build.yml) | Build a container image on push, in a governed build run on Iltero Platform, in three jobs. The first builds the image for each CPU architecture in `IMAGE_PLATFORMS` (`linux/amd64,linux/arm64` by default), pushes it to the GitHub container registry and reads its index back. The second scans the pushed image once for each architecture, with read access to the registry only. The third records the image with every report, keeps the record in the run's artifact store, and closes the build run. | Needed |
| [`image/governed-deployment.yml`](image/governed-deployment.yml) | Deploy a container image to Kubernetes, started by hand with the image's digest, in a governed image deploy run on Iltero Platform. The image's build must already be recorded and sent, as `image/governed-build.yml` does. Around the deployment, steps record each stage and send it: before the deployment they check the image, after it they report the deployed image, and after the rollout they check that every pod of the workload runs it. Each step also keeps its record in the run's artifact store. A second job closes the run. | Needed |

Replace every `0000000000000000000000000000000000000000` with the full commit SHA: the 40-character ID that Git
gives each commit. Use the SHA of the iltero-actions commit you use. Replace the example values with your own, such
as the deploy role's Amazon Resource Name (ARN), the region and the branches; each workflow's header lists its
values. A workflow that needs no account works with a `.iltero/config.yml` that has no `platform` section.
