# Examples

## Infrastructure as code (IaC)

| Workflow | Use | Needs a project linked to Iltero Platform |
| --- | --- | --- |
| [`iac/preview.yml`](iac/preview.yml) | Check each pull request: plan every unit with no credentials and check each plan. A second job posts the result as a comment on the pull request. | No |
| [`iac/deploy.yml`](iac/deploy.yml) | Deploy on push in a project not linked to Iltero Platform: check each unit's plan, apply it, record the deployment, check the deployed resources after the apply, then build and check each record bundle. | No |
| [`iac/tracked-deploy.yml`](iac/tracked-deploy.yml) | Deploy each environment on push, in a tracked run on Iltero Platform: plan each unit and check its plan, run the pre-deploy stage, apply the unit and record it, check the deployed resources after the apply, then close the run. | Yes |
| [`iac/own-terraform.yml`](iac/own-terraform.yml) | Deploy on push in a project not linked to Iltero Platform, with your own Terraform commands: after plan and after apply, a step records that stage of the unit's change on the runner, and a step between them asks the CLI to confirm that the unit's record does not require the pre-deploy stage. A later step checks that the deployed resources still match what the apply left. A last step builds and checks the unit's record bundle. | No |
| [`iac/tracked-own-terraform.yml`](iac/tracked-own-terraform.yml) | Deploy on push in a tracked run on Iltero Platform, with your own Terraform commands: after plan, before apply and after apply, a step records that stage of the unit's change. A later step checks that the deployed resources still match what the apply left. Each step also keeps its record in the run's artifact store. | Yes |

## Container images

| Workflow | Use | Needs a project linked to Iltero Platform |
| --- | --- | --- |
| [`image/build.yml`](image/build.yml) | Build a container image on push, in a project not linked to Iltero Platform, in three jobs. The first builds the image for each CPU architecture in `IMAGE_PLATFORMS` (`linux/amd64,linux/arm64` by default), pushes it to the GitHub container registry and reads its index back. The second scans the pushed image once for each architecture, with read access to the registry only, and fails the workflow when any architecture has a vulnerability at one of the severities in `FAIL_ON_SCAN_SEVERITIES`. The third also runs when the scan failed the workflow after it kept the reports: it checks the image as advice, records it on the runner and uploads the record as a workflow artifact. | No |
| [`image/deployment.yml`](image/deployment.yml) | Deploy a container image to Kubernetes, started by hand with the image's digest, in a project not linked to Iltero Platform. Around the deployment, steps record each stage on the runner: before the deployment they check the image as advice, after it they report the deployed image, and after the rollout they check that every pod of the workload runs it. | No |
| [`image/tracked-build.yml`](image/tracked-build.yml) | Build a container image on push, in a tracked build run on Iltero Platform, in three jobs. The first builds the image for each CPU architecture in `IMAGE_PLATFORMS` (`linux/amd64,linux/arm64` by default), pushes it to the GitHub container registry and reads its index back. The second scans the pushed image once for each architecture, with read access to the registry only. The third records the image with every report, keeps the record in the run's artifact store, and closes the build run. | Yes |
| [`image/tracked-deployment.yml`](image/tracked-deployment.yml) | Deploy a container image to Kubernetes, started by hand with the image's digest, in a tracked image deploy run on Iltero Platform. The image's build must already be recorded and sent, as `image/tracked-build.yml` does. Around the deployment, steps record each stage and send it: before the deployment they check the image, after it they report the deployed image, and after the rollout they check that every pod of the workload runs it. Each step also keeps its record in the run's artifact store. A second job closes the run. | Yes |

Replace every `0000000000000000000000000000000000000000` with the commit SHA of the iltero-actions release you use. Open
the commit linked from the release page and copy its full 40-character ID. Replace each `# v0.3.0` comment with that
release's version, and use the same release for every action. Replace the example values with your own, such as the
deploy role's Amazon Resource Name (ARN), the region and the branches; each workflow's header lists its values. A
workflow that does not need a linked project works with a `.iltero/config.yml` that has no `platform` section.
