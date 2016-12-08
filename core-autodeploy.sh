#!/bin/bash
set -x
####################################################
#
# A simple script to auto-install Zenoss Core 4.2
#
# This script should be run on a base install of
# CentOS 5/6 or RHEL 5/6.
# JC - Added --no-check-certificate to all wget lines
#
###################################################

#
# Variables
#

if [ -f /etc/redhat-release ]; then
	elv=`cat /etc/redhat-release | gawk 'BEGIN {FS="release "} {print $2}' | gawk 'BEGIN {FS="."} {print $1}'`
	els=el$elv
else
	echo "Unable to determine version. I can't continue"
	exit 1
fi

pushd `dirname $0` > /dev/null
SCRIPTPATH=`pwd`
popd > /dev/null

epel_url="https://dl.fedoraproject.org/pub/epel"
epel_name="epel-release"
epel_rpm="$epel_name-latest-$elv.noarch.rpm"

jre_file="jre-6u31-linux-x64-rpm.bin"
jre_url="http://javadl.sun.com/webapps/download/AutoDL?BundleId=59622"

mysql_url="http://www.mirrorservice.org/sites/ftp.mysql.com/Downloads/MySQL-5.5"
mysql_v="5.5.37-1"
mysql_client_rpm="MySQL-client-$mysql_v.linux2.6.x86_64.rpm"
mysql_server_rpm="MySQL-server-$mysql_v.linux2.6.x86_64.rpm"
mysql_shared_rpm="MySQL-shared-$mysql_v.linux2.6.x86_64.rpm"
mysql_compat_rpm="MySQL-shared-compat-$mysql_v.linux2.6.x86_64.rpm"

rmqv=2.8.7
rmq_url="http://www.rabbitmq.com/releases/rabbitmq-server/v${rmqv}"
rmq_rpm="rabbitmq-server-${rmqv}-1.noarch.rpm"

zenoss_build=4.2.5-2108
zenoss_url="http://downloads.sourceforge.net/project/zenoss/zenoss-4.2/zenoss-4.2.5/"
zenoss_rpm="zenoss_core-$zenoss_build.$els.x86_64.rpm"
zenoss_gpg_key="http://wiki.zenoss.org/download/core/gpg/RPM-GPG-KEY-zenoss"

zenossdep_url="http://deps.zenoss.com/yum"
zenossdep_name="zenossdeps"
zenossdep_rpm="$zenossdep_name-4.2.x-1.$els.noarch.rpm"

#
# Helper Functions
#

try() {
	"$@"
	if [ $? -ne 0 ]; then
		die "Command failure: $@"
	fi
}

die() {
	echo $*
	exit 1
}

disable_repo() {
	local conf=/etc/yum.repos.d/$1.repo
	if [ ! -e "$conf" ]; then
		die "Yum repo config $conf not found -- exiting."
	else
		sed -i -e 's/^enabled.*/enabled = 0/g' $conf
	fi
}

enable_service() {
	try /sbin/chkconfig $1 on
	try /sbin/service $1 start
}

disable_service() {
   try /sbin/service $1 stop
   try /sbin/chkconfig $1 off
}

install_local_rpm() {

    rpm_name=$1
    rpm_url=$2
    
    # Attempt local install first
    if [[ -f $SCRIPTPATH/$rpm_name ]]; then
        try yum --nogpgcheck -y localinstall $SCRIPTDIR/$rpm_name

    # If no local package found, try to download it
    elif [[ -n $rpm_url ]]; then
        try wget --no-check-certificate $rpm_url/$rpm_name

        if [ ! -f $rpm_name ];then
            die "Failed to download $rpm_url/$rpm_name. I can't continue"
        fi

        try yum --nogpgcheck -y localinstall $rpm_name
    fi
}

install_repo() {
    repo_name=$1
    repo_rpm=$2
    repo_url=$3

    installed=`rpm -qa $repo_name | grep $repo_name`

    if [[ -z $installed ]]; then
        echo "Installing $repo_name since not present"
        install_local_rpm $repo_rpm $repo_url
    fi
}

install_rpm() {
    rpm_name=$1
    yum_options=$2

    try yum -y $yum_options install $rpm_name
}

#
# Welcome message and license
#

cat <<EOF

Welcome to the Zenoss Core auto-deploy script!

This auto-deploy script installs the Oracle Java Runtime Environment (JRE).
To continue, please review and accept the Oracle Binary Code License Agreement
for Java SE. 

Press Enter to continue.
EOF
read
less licenses/Oracle-BCLA-JavaSE
while true; do
    read -p "Do you accept the Oracle Binary Code License Agreement for Java SE? [y/n]" yn
    case $yn in
        [Yy]* ) echo "Install continues...."; break;;
        [Nn]* ) die "Installation aborted.";;
        * ) echo "Please answer yes or no.";;
    esac
done

#
# System Checks
#

umask 022
unalias -a

if [ -L /opt/zenoss ]; then
	die "/opt/zenoss appears to be a symlink. Please remove and re-run this script."
fi

if [ `rpm -qa | egrep -c -i "^mysql-"` -gt 0 ]; then
cat << EOF

It appears that the distro-supplied version of MySQL is at least partially installed,
or a prior installation attempt failed.

Please remove these packages, as well as their dependencies (often postfix), and then
retry this script:

$(rpm -qa | egrep -i "^mysql-")

EOF
die
fi

echo "Ensuring Zenoss RPMs are not already present"
if [ `rpm -qa | grep -c -i ^zenoss` -gt 0 ]; then
	die "I see Zenoss Packages already installed. I can't handle that"
fi

#Disable SELinux:
echo "Disabling SELinux..."
if [ -e /selinux/enforce ]; then
	echo 0 > /selinux/enforce
fi

if [ -e /etc/selinux/config ]; then
	sed -i -e 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
fi

#Check for and remove existing java
openjdk="$(rpm -qa | grep java.*openjdk)"
if [ -n "$openjdk" ]; then
	echo "Attempting to remove existing OpenJDK..."
	try rpm -e $openjdk
fi

# Scientific Linux 6 includes AMQP daemon, it conflicts with RabbitMQ so disable it
if [ -e /etc/init.d/qpidd ]; then
    echo "Disabling existing AMQP daemon"
    disable_service qpidd
fi

MYTMP="$(PATH=/sbin:/usr/sbin:/bin:/usr/bin mktemp -d)"
cd $MYTMP || die "Couldn't change to temporary directory"

#
# Install new repos
#

echo "Installing EPEL Repo"
if [[ $(cat /etc/redhat-release) =~ ^CentOS ]]; then
    echo "Installing EPEL through CentOS Extras repo"
    install_rpm $epel_name "--enablerepo=extras"
else
    install repo $epel_name $epel_rpm $epel_url
fi

echo "Installing zenossdeps Repo"
install_repo $zenossdep_name $zenossdep_rpm $zenossdep_url

#
# Install packages
#

echo "Installing RabbitMQ"
install_local_rpm $rmq_rpm $rmq_url
enable_service rabbitmq-server

if [ ! -f $jre_file ];then
	echo "Downloading Oracle JRE"
	try wget --no-check-certificate -N -O $jre_file $jre_url
	try chmod +x $jre_file
fi
echo "Installing JRE"
#try ./$jre_file

echo "Installing rrdtool"
install_rpm rrdtool-1.4.7

echo "Downloading and installing MySQL RPMs"
for file in $mysql_client_rpm $mysql_server_rpm $mysql_shared_rpm $mysql_compat_rpm;
do
    install_local_rpm $file http://wiki.zenoss.org/download/core/mysql
done

echo "Installing optimal /etc/my.cnf settings"
cat >> /etc/my.cnf << EOF
[mysqld]
max_allowed_packet=16M
innodb_buffer_pool_size = 256M
innodb_additional_mem_pool_size = 20M
EOF

echo "Configuring MySQL"
enable_service mysql
/usr/bin/mysqladmin -u root password ''
/usr/bin/mysqladmin -u root -h localhost password ''

#
# Install Zenoss
#

echo "Installing Zenoss"
if [ `rpm -qa gpg-pubkey* | grep -c "aa5a1ad7-4829c08a"` -eq 0  ];then
	echo "Importing Zenoss GPG Key"
	try rpm --import $zenoss_gpg_key
fi
install_local_rpm $zenoss_rpm $zenoss_url

#Setup secure_zenoss script to be executed by zenoss user
try cp $SCRIPTPATH/secure_zenoss.sh /opt/zenoss/bin/ 
try chown zenoss:zenoss /opt/zenoss/bin/secure_zenoss.sh
try chmod 0700 /opt/zenoss/bin/secure_zenoss.sh

echo "Securing Zenoss"
try su -l -c /opt/zenoss/bin/secure_zenoss.sh zenoss

try cp $SCRIPTPATH/zenpack_actions.txt /opt/zenoss/var

echo "Configuring and Starting some Base Services and Zenoss..."
for service in memcached snmpd zenoss; do
    enable_service $service
done

echo "Securing configuration files..."
try chmod -R go-rwx /opt/zenoss/etc

cat << EOF
Zenoss Core $zenoss_build install completed successfully!

Please visit http://127.0.0.1:8080 in your favorite Web browser to complete
setup.

NOTE: You may need to disable or modify this server's firewall to access port
8080. To disable this system's firewall, type:

# service iptables save
# service iptables stop
# chkconfig iptables off

Alternatively, you can modify your firewall to enable incoming connections to
port 8080. Here is a full list of all the ports Zenoss accepts incoming
connections from, and their purpose:

	8080 (TCP)                 Web user interface
	11211 (TCP and UDP)        memcached
	514 (UDP)                  syslog
	162 (UDP)                  SNMP traps


If you encounter problems with this script, please report them on the
following wiki page:

http://wiki.zenoss.org/index.php?title=Talk:Install_Zenoss

Thank you for using Zenoss. Happy monitoring!
EOF
