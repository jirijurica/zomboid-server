# Zomboid server

[Project Zomboid](https://projectzomboid.com/) dedicated server on a single AWS EC2 instance. Terraform provisions the
AWS side, Ansible configures the instance itself and small tooling to make managment of Zomboid server easier. Although
the repository is focused on Project Zomboid, the base can be easily reused for any other game.

Once Ansible finishes, the server is already running as the `zomboid-server` systemd service. Admins can talk to it
using `zomboid-cli` command.

To save costs, the `zomboid-reaper` systemd timer shuts down idle instances. Every 15 minutes it checks for connected
players. If nobody is online, it checks again 10 minutes later. If the server is still empty, it stops the server, takes
a new btrfs snapshot of the game and powers off the instance.

## How to start it

### Prerequisites

**Local tooling:**

- [Terraform](https://developer.hashicorp.com/terraform/install) (see `terraform/terraform.tf`
  for the minimum required version)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), configured with
  credentials that have permission to manage VPCs, EC2, EBS, and SSM Parameter Store in the target account
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/index.html)

**AWS account setup:**

- An EC2 key pair in the target region, matching `terraform/config.tf`'s `key_pair_name`
  (defaults to `default`) — create one via the EC2 console or `aws ec2 create-key-pair` before applying, and keep the
  private key somewhere you can SSH with
- An AWS CLI profile/session whose default region matches `terraform/config.tf`'s `region`

### 1. Adjust configuration

Edit `terraform/config.tf` for your deployment:

```hcl
locals {
  region = "eu-central-1"  # AWS region to deploy into
  az = "eu-central-1b"  # Availability zone for the instance + data volume
  env = "prod"  # Environment name used in case of multiple deployments
  key_pair_name = "default"  # Name of an existing EC2 key pair in `region`, for SSH access
  instance_type = "m6a.large"  # EC2 instance size/family — see "Instance type sizing" below
}
```

### 2. Configure SSH access for Ansible

Ansible connects to the instance as the `ubuntu` user via SSH, so it needs to know which private key to use. Add the
following to your `~/.ssh/config`, pointing `IdentityFile` at the private key matching the `key_pair_name` from step 1:

```
Match user ubuntu
    IdentityFile ~/.ssh/<KEY_NAME>
```

### 3. Store secrets in SSM Parameter Store

`bootstrap.sh` helps to initialize secrets (like your SSH allowlist) securely out of this repo in AWS SSM Parameter
Store. It will ask you for each value it needs and take care of storing it for you.

```sh
./bootstrap.sh
```

If you ever need to update a value just run it again with `--override` and it'll let you re-enter and replace what's
stored:

```sh
./bootstrap.sh --override
```

Note that updating a value after the server is already provisioned isn't guaranteed to take effect.

### 4. Provision the infrastructure

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

This creates the VPC, security groups, EC2 instance, and data volume, and waits for cloud-init to format the data volume
as btrfs on first boot.

### 5. Configure the server

```sh
unset AWS_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID AWS_SESSION_TOKEN && $(aws configure export-credentials --format env)
```

To avoid incompatibility between current aws cli v2 way of storing credentials and the way how boto3 library used by
Ansible inventory plugin expects it, set AWS session env variables using the command above.

```sh
cd ansible
ansible-playbook -i inventory.aws_ec2.yml -v install_zomboid.yml
```

These exported credentials are only valid for several minutes, so if Ansible starts failing with message
`Unexpected error while trying to list ec2 regions: An error occurred (RequestExpired) when calling the
DescribeRegions operation: Request has expired.`, just re-run the command above again.

## Server updates

To update the server, terminate the EC2 instance and recreate it by repeating
[Provision the infrastructure](#4-provision-the-infrastructure) and [Configure the server](#5-configure-the-server).
This is the intended workflow, not a fallback - the instance is designed to be fully disposable and safe to terminate at
any time, while game data lives on its own EBS volume and survives the instance being replaced.

Re-running the Ansible playbook against a live instance won't update the server. The playbook is idempotent and skips
steps it has already completed, including the server installation itself, so it's only suited to small repairs, such
as restoring a systemd unit you broke or deleted. For anything larger, replacing the instance is the simpler and more
reliable path.

## Backups

The world's save data lives in btrfs subvolume on the dedicated data volume and a new snapshot is created everytime the
server is turned off. No btrfs knowledge is needed to manage the versions and returning back to a previous one. Be just
aware that snapshots are made within the same EBS volume meaning that they can be helpful if something during play went
wrong, but not if the EBS volume was removed. All of this is handled through `zomboid-saves`, run as root on the
instance.

**To see what versions of the world you have available**, run:

```sh
zomboid-saves list
```

You'll get a list like this, oldest first:

```
Available snapshots to roll back to:
  - @zomboid-20260910-221500
  - @zomboid-20260911-090000
```

**To go back to one of those versions**, run:

```sh
zomboid-saves rollback @zomboid-20260910-221500
```

It'll ask you to confirm, and then:

1. set the current world aside under a new name (it will look like `@zomboid-<DATETIME>-broken`) instead of deleting it,
   and
2. bring the version you picked back as the world the server will load.

Start the server back up afterwards and it'll be running on the restored version. Nothing is lost in the process — if
the version you rolled back to also wasn't what you wanted, the set-aside copy from step 1 is still there and can be
rolled back to as well.

**To delete an old version you no longer need**, run:

```sh
zomboid-saves.sh remove @zomboid-20260910-221500
```

It'll ask you to confirm and then delete it for good — there's no undo, so only remove a version once you're sure you're
done with it.

## Instance type sizing

The Project Zomboid dedicated server needs noticeably more resources than one might expect from a game server. It
isn't a lean, purpose-built server binary; it's much closer to the full game running without graphics. The server
install alone is around 7GB, and its file layout looks very much like the regular game client's. That's simply where
the game is today, and it's the reason behind the sizing below.

Memory is what matters. From testing on this setup, 8GB of RAM is the minimum. Below that, the server was so
unstable it couldn't even finish its first boot. Ansible gives the Java heap always the half of the RAM (4GB in this
case). The Java process uses a fair amount of memory outside the heap as well, so it really needs more than the heap
size. In a 4-player session lasting 4 hours, it settled at around 5.5GB in total and was stable, leaving the rest for
the OS. That's workable but tight. Nothing else on the instance should be allowed to grab a large chunk of memory. This
is also why Ansible disables the Amazon SSM agent, which has been seen consuming CPU and memory mid-game. If cost
optimization isn't your main goal, a 16GB instance is the comfortable choice. CPU doesn't need any attention. 2 vCPUs
are completely enough.

To change the instance type, edit `instance_type` in `terraform/config.tf` and re-run
[Provision the infrastructure](#4-provision-the-infrastructure). Here are some suitable options.

| Instance type    | Resources       | Approx. cost  | Free tier eligible |
|------------------|-----------------|---------------|--------------------|
| `m7i-flex.large` | 2 vCPU / 8 GiB  | $0.11471/hour | Yes                |
| `m6a.large`      | 2 vCPU / 8 GiB  | $0.1035/hour  | No                 |
| `r6a.large`      | 2 vCPU / 16 GiB | $0.1368/hour  | No                 |

The costs are on-demand prices in `eu-central-1` (Frankfurt). They're only there for a rough comparison and will differ
by region and over time. Check the [AWS EC2 pricing page](https://aws.amazon.com/ec2/pricing/on-demand/) for current
prices. `m7i-flex.large` lets you run the server free for months under the AWS free tier, which makes it a good way to
try things out.

[//]: # (## Monitoring)

[//]: # ()
[//]: # (@TODO)
