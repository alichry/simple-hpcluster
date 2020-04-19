# Simple HPC Cluster
In research, AWS ParallelCluster is widely used and is generally utilized by only one user. This repository aims to automate the creation of multi-user clusters (faculty and/or students). A multi-user cluster for faculty can be considered the department's cluster and a multi-user cluster for students is usually a lab cluster.  
AWS ParallelCluster handles the configuration and creation of the cluster while this repository provide a post-install bootstrap script that handles the multi-user configuration among other tools.

## Multi-user for SGE (Grid Engine)
Multi-user mode in SGE can be achieved by synchronizing the users (/etc/passwd) across all nodes or by creating an LDAP server. This is required because SGE checks the job's user passwd entry before execution, and if LDAP is used, it can be possible that jobs might become stuck in an error state.  

```
error_reason: 1: can't get password entry for user "student". \
Either the user does not exist or NIS error!
```
  
By using a simple approach to synchronize the /etc/passwd file, we believe that it is less error-prone than LDAP.  

## Synchronization
Users will be added on the master node using `useradd` or the like. The getpasswd shell script extracts the created users by consulting /etc/passwd, with the exception of the first user created during instance creation (usually `ec2-user`, `centos`, `ubuntu` or ...). This is executed periodically by the root user and the resulting file is saved and is only accessible to other compute nodes using HTTP (nginx).

## Bootstrapper usage
```
Simple multi-user cluster bootstrapper usage:
    bootstrap.sh [OPTIONS]
OPTIONS:
    -h, --help          prints this
    -x, --xtrace        enable printing of executed commands
    -s ROOT, --simulate ROOT
                        simulate this script, package installs will be disabled,
                        crontab will not be modified. esulting files will be
                        saved in ROOT.
    -p PORT, --public-port PORT
                        port to use for the master's public nginx vhosts.
                        Defaults to 80
    -q PORT, --private-port PORT
                        port to use for the master's private nginx vhost
                        (only accessible from the VPC). Defaults to 8080
    -l LOC, --passwd-location LOC
                        Use LOC as the HTTP location for the generated passwd
                        file. Defaults to /users.passwd
    -f LOC, --enable-fallback LOC
                        fallback is required if the compute node was not able
                        to infer the master node's hostname. Disabled by default.
                        LOC is the HTTP location that will point to the passwd
                        file.
    -d DOMAIN, --domain DOMAIN
                        domain name that will point to the master node. This
                        is required if the -f option is used. If this is used
                        without the -f option, this will simply be used in the
                        nginx's vhost configuration directive 'server_name'
    -c NAME TYPE, --cluster NAME TYPE
                        By default, the cluster name and node type is retrieved
                        from cfnconfig that is set by AWS ParallelCluster.
                        This argument will allow you to dictate the cluster's
                        name and note type regardless of ParallelCluster. This
                        is required if not run by AWS ParallelCluster.
                        TYPE is either MasterServer or ComputeFleet
    -g SGE_ROOT, --sge-root SGE_ROOT
                        Bootstrapper expects the environment variable SGE_ROOT
                        to be set. In case it doesn't it will use SGE_ROOT
                        Defaults to /opt/sge
    -m QCONF_PATH, --qconf QCONF_PATH
                        Bootstrapper adds an SMP parallel environment to SGE.
                        If the command qconf was not found, it will use
                        QCONF_PATH instead. Defaults to /opt/sge/bin/lx-amd64/qconf
Note: HTTP location must start with a leading slash.
e.g. -l /users.passwd -f /master.simplehpc
```

## Show me how
Enabling multi-user mode on your cluster is achievable by adding the [`post_install`](https://docs.aws.amazon.com/parallelcluster/latest/ug/cluster-definition.html#post-install) option under the `cluster` section on the ParallelCluster configuration file.  the `post_install` value should point to the bootstrap.sh file shown in this repository:
```
post_install = https://raw.githubusercontent.com/alichry/simple-hpcluster/master/bootstrap.sh
```
The bootstrap script accepts optional arguments, in case of any, specify the arguments in [`post_install_args`](https://docs.aws.amazon.com/parallelcluster/latest/ug/cluster-definition.html#post-install-args)  
### A to Z
* Install and configure [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html)
* Install [AWS ParallelCluster](https://docs.aws.amazon.com/parallelcluster/latest/ug/install.html)
* Configure your cluster using [pcluster configure](https://docs.aws.amazon.com/parallelcluster/latest/ug/getting-started-configuring-parallelcluster.html). If you get authorization errors, make sure your AWS CLI is properly configured, your `~/.aws/credentials` should have a default profile configured:

```
[default]
aws_access_key_id=************
aws_secret_access_key=************
aws_session_token=************
```

* Once your run `plcuster configure`, edit your pcluster configuration file, that is `~/.parallelcluster/config` by default, and add the `post_install` and the optional `post_install_args` keys under the `cluster` section:

```
[cluster]
...
key_name = xxxxxx
initial_queue_size = 0
max_queue_size = 16
maintain_initial_size = true
master_instance_type = t2.micro
master_root_volume_size = 25
compute_instance_type = c5.xlarge
compute_root_volume_size = 25
base_os = centos7
post_install = https://raw.githubusercontent.com/alichry/simple-hpcluster/master/bootstrap.sh
...
```

* Run `plcuster create cluster_name` to create your cluster. 
* Once your cluster is created, you can add users to the master node using `useradd`. Periodically, those added users will be synchronized across the compute nodes depending on the time interval of the cronjob (currently every 10 minutes).
* If you enabled the fallback (`-f LOC -d DOMAIN`) in the `post_install_args`, you need to edit your inbound rules in the Security Group of your Master Node (public) VPC from the AWS Console to allow the public port to be reachable from anywhere (0.0.0.0/0). Additionally, you need to modify your domain's DNS records to make DOMAIN point to the master node's public IP address.
* After `plcuster create cluster_name` exits successfully, it will print the master node's Public IP address. Use `pcluster ssh cluster_name -i PATH_TO_KEY` to establish an SSH connection to the master node.
* Bootstrapper installs [sge-utls](https://github.com/alichry/sge-utils). If you're planning to use jobsub, which is highly recommended in a lab environment, you need to edit the configuration file `/etc/sge-utils/jobsub.conf` to suit your needs. You'll have change the `max_slots` parameter of each parallel environment to match the total number of vCPUs in your cluster.
* Once your connected to the master node, you can add other users using `useradd` and run a test job using jobsub:

```sh
$ jobsub smp 1 echo hello from \`hostname\`
```

* When the cluster is no longer needed, run:

```
$ pcluster stop cluster_name
$ pcluster delete cluster_name
```

## Non-AWS cluster
If you would like to add synchronization support without configuring LDAP and you're clustrer is not configured by AWS ParallelCluster, you have to use the `-c CLUSTER_NAME NODE_TYPE` option of the bootstrapper.



## TODO
* Bootstrapper: 
	* Printing succeeded commands or statuses, currently we only print errors.
	* Provide more flexibility in
		* choosing the public and private webroots,
		* not installing [sge-utils](https://github.com/alichry/sge-utils)