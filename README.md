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
  instance_type = "m7i-flex.large"  # EC2 instance size/family — see "Performance / sizing" below
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

[//]: # (## Performance / sizing)

[//]: # ()
[//]: # (@TODO review and simplification)

[//]: # ()
[//]: # (Project Zomboid's current dedicated server &#40;tested here against **buildid 24909836**, i.e. Build 42&#41; will not even)

[//]: # (initialize with less than **6 GB of RAM**, regardless of player count — this was confirmed by hand on this)

[//]: # (infrastructure, and lines up with community reports that Build 42 needs ~6 GB just to start and isn't reliably stable at)

[//]: # (8 GB once several players are loading new areas simultaneously.)

[//]: # ()
[//]: # (`terraform/config.tf` defaults `instance_type` to `m7i-flex.large` &#40;2 vCPU / 8 GiB&#41;, chosen because it's covered under)

[//]: # (AWS's account-level free-tier credit; `m6a.large` &#40;also 2 vCPU / 8 GiB, AMD EPYC instead of Intel Xeon&#41; is noted)

[//]: # (alongside it as the cheaper on-demand option once free-tier credit isn't a factor. Both are `large`-size general-purpose)

[//]: # (instances, sitting right at the edge of what Build 42 needs for a handful of players.)

[//]: # ()
[//]: # (The table below is a starting-point guide, not a guarantee — actual usage depends heavily on mods &#40;map mods especially&#41;,)

[//]: # (world size explored, and how many concurrent players are actively loading new chunks. It follows the rough community)

[//]: # (rule of thumb of **~6 GB base + ~0.5 GB per additional concurrent player**, mapped onto the nearest `m6a`/`m7i-flex`)

[//]: # (instance size &#40;both families keep a fixed 4:1 GiB-to-vCPU ratio, so sizes scale identically&#41;:)

[//]: # ()
[//]: # (| Concurrent players       | Estimated RAM need | Instance size      | vCPU / RAM           | EBS data volume         |)

[//]: # (|--------------------------|--------------------|--------------------|----------------------|-------------------------|)

[//]: # (| 1–4 &#40;solo / small group&#41; | ~6–8 GB            | `large`            | 2 vCPU / 8 GiB       | 10 GB &#40;current default&#41; |)

[//]: # (| 5–10                     | ~8.5–11 GB         | `xlarge`           | 4 vCPU / 16 GiB      | 15–20 GB                |)

[//]: # (| 11–16                    | ~11.5–14 GB        | `xlarge`–`2xlarge` | 4–8 vCPU / 16–32 GiB | 25–30 GB                |)

[//]: # (| 17–32 &#40;community server&#41; | ~14.5–22 GB        | `2xlarge`          | 8 vCPU / 32 GiB      | 40 GB+                  |)

[//]: # ()
[//]: # (Notes:)

[//]: # ()
[//]: # (- vCPU headroom matters less than RAM for Project Zomboid — the server is largely single-thread bound, so extra cores)

[//]: # (  mostly help with concurrent I/O and mod-heavy world simulation rather than raw throughput. Don't undersize RAM to)

[//]: # (  "afford" more cores.)

[//]: # (- The EBS data volume only needs to hold the save data plus however many btrfs snapshots you keep around &#40;see above&#41; —)

[//]: # (  heavily modded/explored worlds and longer snapshot retention both push this up. `terraform/main.tf` currently)

[//]: # (  provisions 10 GB; bump `aws_ebs_volume.data.size`)

[//]: # (  as needed &#40;it's a live resize — no data loss — but the in-guest filesystem must be grown to match&#41;.)

[//]: # (- To change instance size, edit `instance_type` in `terraform/config.tf` and re-`apply`.)

[//]: # ()
[//]: # (## Monitoring)

[//]: # ()
[//]: # (@TODO)
