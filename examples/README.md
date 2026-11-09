# Examples

| Workflow | Use | Iltero account |
| --- | --- | --- |
| [`preview.yml`](preview.yml) | Check each pull request: plan every unit with no credentials and check each plan. A second job posts the result as a comment on the pull request. | Not needed |
| [`deploy.yml`](deploy.yml) | Deploy on push with no Iltero account: check each unit's plan, apply it, record the deployment, check the deployed resources after the apply, then pack and check each record. | Not needed |
| [`record-iac.yml`](record-iac.yml) | Deploy on push in a governed run on Iltero Platform, with your own Terraform commands: after plan, before apply and after apply, a step records that stage of the unit's change. A later step checks that the deployed resources still match what the apply left. Each step also keeps its record in the run's artifact store. | Needed |
| [`record-image.yml`](record-image.yml) | Build a container image on push, in a governed build run on Iltero Platform, in three jobs. The first builds the image for two CPU architectures (linux/amd64 and linux/arm64), pushes it to the GitHub container registry and reads its index back. The second scans the pushed image, with read access to the registry only. The third records the image and closes the build run. | Needed |
| [`record-image-deployment.yml`](record-image-deployment.yml) | Deploy a container image to Kubernetes, started by hand with the image's digest, with no Iltero account. Around the deployment, steps record each stage on the runner: before the deployment they check the image as advice, after it they report the deployed image, and after the rollout they check that every pod of the workload runs it. | Not needed |
| [`greenfield.yml`](greenfield.yml) | Deploy each environment on push, in a governed run on Iltero Platform: plan each unit and check its plan, run the pre-deploy stage, apply the unit and record it, check the deployed resources after the apply, then close the run. | Needed |

Replace every `0000000000000000000000000000000000000000` with the full commit SHA: the 40-character ID that Git
gives each commit. Use the SHA of the iltero-actions commit you use. Replace the example values with your own, such
as the deploy role's Amazon Resource Name (ARN), the region and the branches; each workflow's header lists its
values. A workflow that needs no account works with a `.iltero/config.yml` that has no `platform` section.
