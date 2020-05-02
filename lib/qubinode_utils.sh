#!/bin/bash


function qubinode_project_cleanup () {
    # resets the project to a clean state by removing all vars files
    # ensure requirements are in place
    qubinode_required_prereqs

    # ensure VMs aren't in a running state before proceeding
    VMSTATE=$(sudo virsh list --all |  awk '{ print $3}')
    if [ "A$VMSTATE" = "Arunning" ]
    then 
        printf "%s\n" " "
        printf "%s\n" "Running this command will remove all the vars files" 
        printf "%s\n" "which will become troublesome later on when you're trying to delete the cluster"
        printf "%s\n" "using the qubinode-installer with the -d option"
        confirm "${yel} Do you want to continue?${end} ${blu}yes/no ${end}"
        if [ "A${response}" != "Ayes" ]
        then
           exit 1
        else    
             FILES=()
             mapfile -t FILES < <(find "${project_dir}/inventory/" -not -path '*/\.*' -type f)
            if [ -f "$vault_vars_file" ] && [ -f "$vault_vars_file" ]
            then
                FILES=("${FILES[@]}" "$vault_vars_file" "$vars_file")
            fi
        fi
    fi        

    # Delete OpenShift 3 files
    if [ -f ${project_dir}/playbooks/vars/ocp3.yml ]
    then 
        openshift_product=$(awk '/^product:/ {print $2}' "${project_dir}/playbooks/vars/ocp3.yml")
        if [[ ${openshift_product} == "ocp3" ]]; then
          FILES=("${FILES[@]}" "$ocp3_vars_files")
        elif [[ ${openshift_product} == "okd3" ]]; then
          FILES=("${FILES[@]}" "$okd3_vars_files")
        fi

        if [ ${#FILES[@]} -eq 0 ]
        then
            echo "Project directory: ${project_dir} state is already clean"
        else
            for f in $(echo "${FILES[@]}")
            do
                test -f $f && rm $f
                echo "purged $f"

            done
        fi
    fi

   echo "Removing playbook vars"
   rm -rvf ${project_dir}/playbooks/vars/*.yml > /dev/null
   echo "Removing downloaded roles"
   rm -rvf ${project_dir}/playbooks/roles/* > /dev/null
}

function cleanStaleKnownHost () {
    user=$1
    host=$2
    alt_host_name=$3
    isKnownHostStale=$(ssh -o connecttimeout=2 -o stricthostkeychecking=no ${user}@${host} true 2>&1|grep -c "Offending")
    if [ "A${isKnownHostStale}" == "A1" ]
    then
        ssh-keygen -R ${host} >/dev/null 2>&1
        if [ "A${alt_host_name}" != "A" ]
        then
            ssh-keygen -R ${alt_host_name} >/dev/null 2>&1
        fi
    fi
}

function canSSH () {
    user=$1
    host=$2
    RESULT=$(ssh -q -o StrictHostKeyChecking=no -o "BatchMode=yes" -i /home/${user}/.ssh/id_rsa "${user}@${host}" "echo 2>&1" && echo SSH_OK || echo SSH_NOK)
    echo $RESULT
}



function get_admin_user_password () {
    #echo " Fetching the Admin user password."
    decrypt_ansible_vault "${vault_vars_file}" > /dev/null
    admin_user_passowrd=$(awk '/admin_user_password:/ {print $2}' "${vault_vars_file}")
    encrypt_ansible_vault "${vaultfile}" >/dev/null
    if [ "A${admin_user_passowrd}" == "A" ]
    then
        print "%s\n" " Unable to retrieve ${yel}$CURRENT_USER${end} user password from the vault"
        exit 1
    fi
}

function exit_status () {
    RESULT=$?
    FAIL_MSG=$1
    LINE=$2
    if [ "A${RESULT}" != "A0" ]
    then
        echo "LINE $LINE - FAILED TO COMPLETE: ${FAIL_MSG}"
        exit "${RESULT}"
    fi
}


convertB_human() {
    # Thanks to https://bit.ly/39xomtN
    NUMBER=$1
    for DESIG in Bytes KB MB GB TB PB
    do
        [ $NUMBER -lt 1024 ] && break
        let NUMBER=$NUMBER/1024
    done

    DISK_SIZE_HUMAN=$(printf "%d %s\n" $NUMBER $DESIG)
    DISK_SIZE_COMPARE=$(printf "%d %s\n" $NUMBER)
}

function isvmRunning () {
    sudo virsh list |grep $vm|awk '/running/ {print $2}'
}

function isvmShutdown () {
    sudo virsh list --all | grep $vm| awk '/shut/ {print $2}'
}

function dnf_or_yum(){
     RHEL_VERSION=$(awk '/rhel_version/ {print $2}' "${vars_file}")
     if [[ $RHEL_VERSION == "RHEL8" ]]; then 
        echo "dnf"
     elif [[ $RHEL_VERSION == "RHEL7" ]]; then
        echo "yum"
     fi 
}

function collect_system_information() {

    which virsh > /dev/null 2>&1 || sudo yum group install virtualization-host-environment -y -q > /dev/null 2>&1
    which virsh > /dev/null 2>&1 || sudo yum install libvirt-client libvirt deltarpm -y -q > /dev/null 2>&1
    which dmidecode > /dev/null 2>&1 || sudo yum install dmidecode -y -q > /dev/null 2>&1
    sudo systemctl restart libvirtd
    MANUFACTURER=$(sudo dmidecode --string system-manufacturer)
    PRODUCTNAME=$(sudo dmidecode --string baseboard-product-name)
    AVAILABLE_MEMORY=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    AVAILABLE_HUMAN_MEMORY=$(free -h | awk '/Mem/ {print $2}')


    libvirt_pool_name=$(cat playbooks/vars/kvm_host.yml | grep libvirt_pool_name: | awk '{print $2}')
    if [ "A${libvirt_pool_name}" == "Adefault" ]
    then
        if ! sudo virsh pool-info default > /dev/null 2>&1
        then
cat > /tmp/libvirt-vol.xml <<EOF
<pool type='dir'>
  <name>default</name>
  <capacity unit='bytes'>0</capacity>
  <allocation unit='bytes'>0</allocation>
  <available unit='bytes'>0</available>
  <source>
  </source>
  <target>
    <path>/var/lib/libvirt/images</path>
  </target>
</pool>
EOF
            sudo virsh pool-define /tmp/libvirt-vol.xml > /dev/null 2>&1
            sudo virsh pool-autostart default > /dev/null 2>&1
            sudo virsh pool-start default > /dev/null 2>&1
        fi
    fi

    AVAILABLE_STORAGE=$(sudo virsh pool-list --details | grep "${libvirt_pool_name}" |awk '{print $5*1024}')
    AVAILABLE_HUMAN_STORAGE=$(sudo virsh pool-list --details | grep "${libvirt_pool_name}" |awk '{print $5,$6}')
}

function create_qubinode_profile_log () {
    if [[ ! -f qubinode_profile.log ]]; then
        rm -rf qubinode_profile.log
        collect_system_information
cat >qubinode_profile.log<<EOF
Manufacturer: ${MANUFACTURER}
Product Name: ${PRODUCTNAME}

System Memory
*************
Avaliable Memory: ${AVAILABLE_MEMORY}
Avaliable Human Memory: ${AVAILABLE_HUMAN_MEMORY}

Storage Information
*******************
Avaliable Storage: ${AVAILABLE_STORAGE}
Avaliable Human Storage: ${AVAILABLE_HUMAN_STORAGE}

CPU INFO
***************
$(lscpu | egrep 'Model name|Socket|Thread|NUMA|CPU\(s\)')
EOF

    fi

    echo "SYSTEM REPORT"
    cat qubinode_profile.log
}

function check_disk_size () {
    # STORAGE
    MIN_STORAGE=$(awk '/qubinode_minimal_storage:/ {print $2}' "${vars_file}")
    STANDARD_STORAGE=$(awk '/qubinode_standard_storage:/ {print $2}' "${vars_file}")
    PERFORMANCE_STORAGE=$(awk '/qubinode_performance_storage:/ {print $2}' "${vars_file}")
    MIN_STORAGE=${MIN_STORAGE:-370}
    STANDARD_STORAGE=${STANDARD_STORAGE:-900}
    PERFORMANCE_STORAGE=${PERFORMANCE_STORAGE:-1000}
    POOL=$(sudo virsh pool-list --autostart | awk '/active/ {print $1}'| grep -v qbn)
    POOL_CAPACITY=$(sudo virsh pool-dumpxml "${POOL}"| grep capacity | grep -Eo "[[:digit:]]{1,100}")
    DISK=$(cat "${kvm_host_vars_file}" | grep kvm_host_libvirt_extra_disk: | awk '{print $2}')

    if rpm -qf /bin/lsblk > /dev/null 2>&1
    then
        # If not setting system as a Qubinode then the
        # variable POOL_CAPACITY should be defined. Use it to
        # determine if there is enough storage to continue
        if [ "A${POOL_CAPACITY}" != "A" ]
        then
            convertB_human $POOL_CAPACITY
        else
            DISK_INFO=$(lsblk -dpb | grep $DISK)
            CURRENT_DISK_SIZE=$(echo $DISK_INFO| awk '{print $4}')
            convertB_human $CURRENT_DISK_SIZE
        fi

        # Set the system storage profile based on disk or libvirt pool capacity
        if [[ $DISK_SIZE_COMPARE -ge $MIN_STORAGE ]] && [[ $DISK_SIZE_COMPARE -lt $STANDARD_STORAGE ]]
        then
            printf "%s\n" " The storage size $DISK_SIZE_HUMAN meets the minimum storage requirement of $MIN_STORAGE GB"
            STORAGE_PROFILE=minimal
        elif [[ $DISK_SIZE_COMPARE -ge $STANDARD_STORAGE ]] && [[ $DISK_SIZE_COMPARE -lt $PERFORMANCE_STORAGE ]]
        then
            printf "%s\n" " The storage size $DISK_SIZE_HUMAN meets the standard storage requirement of $STANDARD_STORAGE GB"
            STORAGE_PROFILE=standard
        elif [[ $DISK_SIZE_COMPARE -ge $PERFORMANCE_STORAGE ]]
        then
            printf "%s\n" " The storage size $DISK_SIZE_HUMAN meets the performance storage requirement of $PERFORMANCE_STORAGE GB"
            STORAGE_PROFILE=performance
        else
           printf "%s\n" " The storage size $DISK_SIZE_HUMAN does not meet the minimum size of the $MIN_STORAGE GB"
            STORAGE_PROFILE=notmet
        fi
    else
        printf "%s\n" " The utility /bin/lsblk is missing. Please install the util-linux package."
        exit 1
    fi
}

function check_memory_size () {
    
    MINIMAL_MEMORY=$(awk '/qubinode_minimal_memory:/ {print $2}' "${vars_file}")
    STANDARD_MEMORY=$(awk '/qubinode_standard_memory:/ {print $2}' "${vars_file}")
    PERFORMANCE_MEMORY=$(awk '/qubinode_performance_memory:/ {print $2}' "${vars_file}")
    
    MINIMAL_MEMORY=${MINIMAL_MEMORY:-30}
    STANDARD_MEMORY=${STANDARD_MEMORY:-80}
    PERFORMANCE_MEMORY=${PERFORMANCE_MEMORY:-88}

    TOTAL_MEMORY=$(free -g|awk '/^Mem:/{print $2}')
    
    if [[ $TOTAL_MEMORY -ge $MINIMAL_MEMORY ]] && [[ $TOTAL_MEMORY -lt $STANDARD_MEMORY ]]
    then
        printf "%s\n" " The memory size $TOTAL_MEMORY GB meets the minimum memory requirement of $MINIMAL_MEMORY GB"
        MEMORY_PROFILE=minimal
    elif [[ $TOTAL_MEMORY -ge $STANDARD_MEMORY ]] && [[ $TOTAL_MEMORY -lt $PERFORMANCE_MEMORY ]]
    then
        printf "%s\n" " The memory size $TOTAL_MEMORY GB meets the standard memory requirement of $STANDARD_MEMORY GB"
        MEMORY_PROFILE=standard
    elif [[ $TOTAL_MEMORY -ge $PERFORMANCE_MEMORY ]]
    then
        printf "%s\n" " The memory size $TOTAL_MEMORY GB meets the performance memory requirement of $PERFORMANCE_MEMORY GB"
        MEMORY_PROFILE=performance
    else
       printf "%s\n" " The memory size $TOTAL_MEMORY GB does not meet the minimum size of the $MINIMAL_MEMORY GB"
       MEMORY_PROFILE=notmet
    fi

    sed -i "s/storage_profile:.*/storage_profile: "$STORAGE_PROFILE"/g" "${vars_file}"
    sed -i "s/memory_profile:.*/memory_profile: "$MEMORY_PROFILE"/g" "${vars_file}"
}

function check_hardware_resources () {
    check_disk_size
    check_memory_size

    #if [[ "$STORAGE_PROFILE" != "$MEMORY_PROFILE" ]] && [[ "$STORAGE_PROFILE" != minimal ]] && [[ "$MEMORY_PROFILE" != minimal ]]
    if [ "$STORAGE_PROFILE" == "$MEMORY_PROFILE" ]
    then
        local PROFILE=$MEMORY_PROFILE
    elif [[ "$STORAGE_PROFILE" != notmet ]] && [[ "$MEMORY_PROFILE" != notmet ]] && [[ "$STORAGE_PROFILE" != minimal ]] && [[ "$MEMORY_PROFILE" != minimal ]]
    then
        local PROFILE=standard
    elif [[ "$STORAGE_PROFILE" != notmet ]] && [[ "$MEMORY_PROFILE" != notmet ]]
    then
        local PROFILE=minimal
    else
        local PROFILE=notmet
    fi
   
    sed -i "s/ocp_cluster_size:.*/ocp_cluster_size: "$PROFILE"/g" "${vars_file}"
#    elif [[ "$STORAGE_PROFILE" != "$MEMORY_PROFILE" ]] && [[ "$STORAGE_PROFILE" == minimal ]] || [[ "$MEMORY_PROFILE" == minimal ]]
#    then
#        local PROFILE=minimal
#        sed -i "s/storage_profile:.*/storage_profile: "$PROFILE"/g" "${vars_file}"
#        sed -i "s/memory_profile:.*/memory_profile: "$PROFILE"/g" "${vars_file}"
#    else
#        sed -i "s/storage_profile:.*/storage_profile: "$STORAGE_PROFILE"/g" "${vars_file}"
#        sed -i "s/memory_profile:.*/memory_profile: "$MEMORY_PROFILE"/g" "${vars_file}"
#    fi

}

