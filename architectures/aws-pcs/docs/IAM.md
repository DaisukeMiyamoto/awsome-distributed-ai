# IAM Permissions Guide

The cluster distinguishes **two human roles** with very different
responsibilities. Each ships a CloudFormation template that creates the
customer-managed IAM policy and an IAM group with it attached (optionally
adding existing IAM users at deploy time).

| Role | Can do | Template · Launch |
|---|---|---|
| **Cluster admin** — deploys/updates/deletes clusters | Full CRUD on CloudFormation, PCS, EC2 (VPC/SG/launch templates/placement groups/NAT/EIP), FSx, scoped IAM, SSM Parameter Store, KMS, Secrets Manager, and (optionally) Image Builder. **Broad — do not hand to every engineer.** | [`cluster-admin-iam.yaml`](../assets/cluster-admin-iam.yaml) · [![Launch](../images/launch-stack.svg)](https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateUrl=https://awsome-distributed-ai.s3.amazonaws.com/templates/aws-pcs/cluster-admin-iam.yaml&stackName=pcs-cluster-admins) |
| **Cluster user** — engineers running jobs on an existing cluster | SSM session to the **login node only**, port-forward Grafana, read the Grafana password, read PCS cluster/queue status. Cannot create, modify, or delete anything, and cannot shell into compute nodes. **Safe to hand out widely.** | [`cluster-user-iam.yaml`](../assets/cluster-user-iam.yaml) · [![Launch](../images/launch-stack.svg)](https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateUrl=https://awsome-distributed-ai.s3.amazonaws.com/templates/aws-pcs/cluster-user-iam.yaml&stackName=pcs-cluster-users) |

---

## Deploying the policies

From the CLI (use `--template-body` against a local checkout for a pre-merge
sandbox test):

```bash
# Admin: create the policies + group, attach existing users, include Image Builder perms
aws cloudformation create-stack \
  --stack-name pcs-cluster-admins \
  --template-body file://architectures/aws-pcs/assets/cluster-admin-iam.yaml \
  --parameters ParameterKey=AttachUsers,ParameterValue=alice,bob \
               ParameterKey=AttachImageBuilderPolicy,ParameterValue=true \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM

# User: create the policy + group, attach existing users
# ClusterStackName scopes SSM session access to that one cluster's login node —
# deploy one stack of this template per cluster.
aws cloudformation create-stack \
  --stack-name pcs-cluster-users-pcs-ml-cluster \
  --template-body file://architectures/aws-pcs/assets/cluster-user-iam.yaml \
  --parameters ParameterKey=ClusterStackName,ParameterValue=pcs-ml-cluster \
               ParameterKey=AttachUsers,ParameterValue=carol,dave \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
```

`AttachUsers` is optional — leave it empty and add users to the group later
via IAM console/CLI. `AttachImageBuilderPolicy` defaults to `false`; enable
it only if the admin will also deploy the standalone DLAMI builder
(`pcs-ready-dlami-with-enroot-pyxis.yaml`).

### What the cluster user can do once attached

```bash
STACK_NAME=pcs-ml-cluster        # your CloudFormation stack name
AWS_REGION=us-east-1             # your region

# Find the login node's instance ID via the PCS API — no dependency on tag naming
CLUSTER_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'Stacks[0].Outputs[?OutputKey==`ClusterId`].OutputValue' --output text)
[ -n "$CLUSTER_ID" ] && [ "$CLUSTER_ID" != "None" ] || { echo "No ClusterId — check STACK_NAME/AWS_REGION"; return 1; }

LOGIN_CNG_ID=$(aws pcs list-compute-node-groups --cluster-identifier "$CLUSTER_ID" --region "$AWS_REGION" --query 'computeNodeGroups[?name==`login`].id' --output text)
LOGIN_INSTANCE_ID=$(aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=tag:aws:pcs:compute-node-group-id,Values=$LOGIN_CNG_ID" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Open a session
aws ssm start-session --target "$LOGIN_INSTANCE_ID" --region "$AWS_REGION"

# Port-forward Grafana (443 -> 8443), then open https://localhost:8443/grafana/
aws ssm start-session --target "$LOGIN_INSTANCE_ID" --region "$AWS_REGION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["443"],"localPortNumber":["8443"]}'

# Read the Grafana admin password
aws ssm get-parameter --name "/pcs/${CLUSTER_ID}/grafana/admin-password" --region "$AWS_REGION" \
  --with-decryption --query 'Parameter.Value' --output text
```

---

## Considerations

These are **sample, slightly-broader-than-strict-least-privilege** policies,
derived from the AWS-published
[minimum permissions for an AWS PCS service administrator](https://docs.aws.amazon.com/pcs/latest/userguide/security-min-permissions.html)
plus the extra permissions the all-in-one template needs because it provisions
VPC + FSx + IAM roles itself (the AWS reference policy assumes those already
exist). Review and tighten before production use.

**Login-node access is scoped to one stack.** The user policy conditions
`ssm:StartSession` on `ssm:resourceTag/Name` equalling
`<ClusterStackName>-login` (exact match, no wildcards) — the Name tag every
login node carries by default. The tag is operator-mutable; if you re-tag
the login node, update the policy condition to match.

**Combined CRUD is intentional, not a mistake.** The admin policy covers
create + update + delete in one policy because (1) CFN rollback on a failed
Create requires Delete actions, (2) UpdateStack is operationally a superset of
Create (it may replace resources), and (3) drift detection during Update calls
Describe across every service. If you want a read-only variant, reduce the same
actions to `*:Describe*` / `*:Get*` / `*:List*` for an auditor role.

**The admin policy is split into core + Image Builder** because the combined
document exceeds IAM's 6,144-character per-policy limit. The core covers a
normal deploy; the Image Builder add-on is only needed for the standalone
DLAMI builder.

**Pairing with AWS-managed policies.** For a smaller customer-managed
surface, attach AWS-managed policies for parts of the stack and trim the
matching statements: `AWSCloudFormationFullAccess`, `AmazonFSxFullAccess`,
`AWSImageBuilderFullAccess` are reasonable fits. Avoid
`AmazonEC2FullAccess` — it is materially overprivileged (e.g. EBS
public-share); prefer the customer-managed EC2 statements in the template.
There is no `AmazonPCSFullAccess`, so the PCS portion has to stay
customer-managed.

### Not covered by these policies

- **The compute instance role** (passed to EC2 by `cluster.yaml`) — provisioned
  by the templates themselves; use the AWS-managed `AWSPCSComputeNodePolicy`.
- **The Image Builder build instance role** — use the AWS-managed
  `EC2InstanceProfileForImageBuilder` /
  `EC2InstanceProfileForImageBuilderECRContainerBuilds`.
- **Fine-grained per-cluster scoping** — both policies use `Resource: "*"` for
  many EC2/VPC actions because resource-level scoping there is limited. This is
  a deliberate sample-grade choice.

### Refining to least-privilege via CloudTrail

To generate a tighter policy from real usage:

1. Deploy a representative cluster in a sandbox account with broad permissions on
   the deploying principal (so nothing fails for spurious IAM reasons).
2. Let the full lifecycle run — deploy, then `delete-stack` — so CloudTrail
   captures every API call.
3. Generate a policy from CloudTrail with IAM Access Analyzer
   (`aws accessanalyzer start-policy-generation` → `get-generated-policy`), then
   diff against the template's statements. Access Analyzer output is usually
   *narrower* on actions but leaves `Resource: "*"`; the template's resource ARNs
   are usually the keepers.

The same approach works for the user policy — exercise the user workflows
(start a session, port-forward Grafana, terminate it) in a sandbox, then narrow.

---

## Verifying the policies

To confirm the admin policy can deploy a cluster end-to-end and the user
policy is correctly constrained (login-only SSM, no LDAP-password access),
see the reproducible procedure in [tests/iam-test.md](../tests/iam-test.md).

> **Private template bucket:** the admin policy grants no `s3:GetObject`
> because the production templates live in the public
> `awsome-distributed-ai` bucket (CFN fetches `--template-url`
> anonymously). If you host the templates in a private bucket, grant
> `s3:GetObject` on that bucket separately.
