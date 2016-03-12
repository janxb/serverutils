#!/bin/bash
set -e

COMMAND=$1
DIR=$(dirname "$(readlink -f "$0")")
MIN_EXPORT_FOLDER_LENGTH=1

# include settings
source $DIR/backup.conf

BINARY=$(/usr/bin/which obnam)
OBNAM="$BINARY\
 --repository=$LOCAL_STORAGE_MOUNT/$OBNAM_REPO_NAME\
 --client-name=backup\
 --keep=30d\
 --no-leave-checkpoints\
 --one-file-system\
 --exclude-caches\
 --compress-with=none\
 --lock-timeout=10\
 --lru-size=100mb\
 --upload-queue-size=50mb\
 --root=$FOLDERS_TO_BACKUP,$LOCAL_EXPORT_FOLDER\
 --exclude=$FOLDERS_TO_EXCLUDE\
"

MYSQL_OUTPUT=$LOCAL_EXPORT_FOLDER"/mysql"
PACKAGES_OUTPUT=$LOCAL_EXPORT_FOLDER"/aptclone"

##########################################################

function trap_error_exit {
	unmount_data
	unmount_storage
	log_error_info "Script exited with Error!"
	exit 99
}

trap trap_error_exit ERR

function trap_exit_unmount {
	#unmount_data
	#unmount_storage
	PLACEHOLDER=1
}

trap trap_exit_unmount 0

function timestamp {
	echo $(date +"%d.%m.%y/%T")
}

function log_info {
	echo $(timestamp) "INFO:" $@
}

function log_error_info {
	echo $(timestamp) "ERROR:" $@
}

function log_error {
	>&2 echo $(timestamp) "ERROR:" $@
	trap_error_exit
	exit 99
}

if [[ -z "${BINARY// }" ]]; then
	log_error "No obnam binary found"
fi

function backup_mysql {
	log_info "Creating MySQL backup"
        rm $MYSQL_OUTPUT/* &> /dev/null || true
        rmdir $MYSQL_OUTPUT &> /dev/null || true
        mkdir -p $MYSQL_OUTPUT
        databases=`mysql --user=$MYSQL_USER --password=$MYSQL_PASS -e "SHOW DATABASES;" | tr -d "| " | grep -v Database`
        for db in $databases; do
                mysqldump --force --opt --user=$MYSQL_USER --password=$MYSQL_PASS --databases $db --skip-add-locks --skip-lock-tables > $MYSQL_OUTPUT/$db.sql
        done
	log_info "MySQL backup finished"
}

function backup_packages {
	README_CONTENT="To restore the Packages, execute \"apt-clone restore FILENAME\""
	log_info "Creating Packages backup"
        rm $PACKAGES_OUTPUT/* &> /dev/null || true
        rmdir $PACKAGES_OUTPUT &> /dev/null || true
        mkdir -p $PACKAGES_OUTPUT

	aptclone_binary=$(/usr/bin/which apt-clone)
	dpkgrepack_binary=$(/usr/bin/which dpkg-repack)
	if [[ -z "${aptclone_binary// }" ]]; then
		log_error "No apt-clone binary found"
	fi
	if [[ -z "${dpkgrepack_binary// }" ]]; then
		log_error "No dpkg-repack binary found"
	fi

	apt-clone clone --with-dpkg-repack $PACKAGES_OUTPUT &> /dev/null
	echo $README_CONTENT > $PACKAGES_OUTPUT/README

	log_info "Packages backup finished"
}

function mount_data {
	if [ -d $LOCAL_BACKUP_MOUNT ]; then
		log_error "Local Snapshot Mount $LOCAL_BACKUP_MOUNT is not empty!"
	else
		mkdir -p $LOCAL_BACKUP_MOUNT
		exec_command "$OBNAM mount --to $LOCAL_BACKUP_MOUNT"
		(mountpoint -q $LOCAL_BACKUP_MOUNT && log_info "Snapshots mounted to $LOCAL_BACKUP_MOUNT") \
			|| log_error "Could not mount Snapshots to $LOCAL_BACKUP_MOUNT"
	fi
}

function unmount_data {
	umount $LOCAL_BACKUP_MOUNT &> /dev/null || true
        rmdir $LOCAL_BACKUP_MOUNT &> /dev/null || true
        (mountpoint -q $LOCAL_BACKUP_MOUNT && log_error "Could not unmount Snapshots from $LOCAL_BACKUP_MOUNT") \
		|| log_info "Unmounted Snapshots from $LOCAL_BACKUP_MOUNT"
}

function mount_storage {
        if [ -d $LOCAL_STORAGE_MOUNT ]; then
                log_error "Local Storage Mount $LOCAL_STORAGE_MOUNT is not empty!"
        else
                mkdir -p $LOCAL_STORAGE_MOUNT
                mount $REMOTE_STORAGE_PATH $LOCAL_STORAGE_MOUNT #-o nolock #> /dev/null 2>&1
                (mountpoint -q $LOCAL_STORAGE_MOUNT && log_info "Storage mounted to $LOCAL_STORAGE_MOUNT") \
			|| log_error "Could not mount Storage to $LOCAL_STORAGE_MOUNT"
        fi
}

function unmount_storage {
        umount $LOCAL_STORAGE_MOUNT &> /dev/null || true
        rmdir $LOCAL_STORAGE_MOUNT &> /dev/null || true
        (mountpoint -q $LOCAL_STORAGE_MOUNT && log_error "Could not unmount Storage from $LOCAL_STORAGE_MOUNT") \
		|| log_info "Unmounted Storage from $LOCAL_STORAGE_MOUNT"
}

function backup_run {
	log_info "Starting Backup.."
	exec_command $OBNAM backup
	log_info "Backup finished."
}

function clean_export_folder {
	export_folder_length=${#LOCAL_EXPORT_FOLDER};
	if [ "$export_folder_length" -gt $MIN_EXPORT_FOLDER_LENGTH ]; then
		rm $MYSQL_OUTPUT/* &> /dev/null || true
		rm $PACKAGES_OUTPUT/* &> /dev/null || true
		rmdir $MYSQL_OUTPUT &> /dev/null || true
		rmdir $PACKAGES_OUTPUT &> /dev/null || true
		rmdir $LOCAL_EXPORT_FOLDER &> /dev/null || true
		log_info "Local Export Folder cleaned"
	else 
		log_error "Cant clean Export Folder, is it root!?"
	fi;
}

function exec_command {
	set +e
	$@
	return_code=$?
	set -e

	if [ "$return_code" -gt "0" ]; then
    		log_error "Error while running Command: "$COMMAND
	else
		#log_info "Finished Command: "$COMMAND
		PLACEHOLDER=1
	fi
}

case $COMMAND in
        "create")
                backup_mysql
		backup_packages
                mount_storage
                backup_run
		clean_export_folder
		unmount_storage
                ;;
        "mount")
                mount_storage
                mount_data
                ;;
        "unmount")
		unmount_data
		unmount_storage
                ;;
        "cleanup")
		log_info "Cleaning up Backup.."
		clean_export_folder
		mount_storage
		exec_command "$OBNAM force-lock"
		log_info "Backup cleaned, Repository unlocked"
		unmount_storage
                ;;
	"help")
		echo "Backup Script. Usage: [ create | mount | unmount | cleanup | commands ]"
                ;;
	"commands")
		$BINARY help
                ;;
        *)
		mount_storage
		log_info "Running Command: $@"
                exec_command $OBNAM $@
		unmount_storage
                ;;
esac
