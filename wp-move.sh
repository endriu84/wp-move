#!/usr/bin/env bash

# Exit on (non catched) error 
set -e

# Treat unset variables as an error when substituting
# set -u

# debuging
# set -x

# variables
project_dir=${PWD}
project_name=${PWD##*/}
move_script_dir=$(dirname "$0")
wp_move_file="wp-move.json"
wp_move_ignore=".wp-move-ignore"
wp_config_extra="wp-config-extra.php"
todays_date=$(date +%Y-%m-%d)
lock_file="wp-move-lock-file"

# Functions

parse_config() {

    if [ ! -r "${project_dir}/${wp_move_file}" ]; then
        error
        printf "No %s file, or no permissions" "${project_dir}/${wp_move_file}"
        exit 1;
    fi

    name=$(jq -r '.name' "${project_dir}/${wp_move_file}")
    local_url=$(jq -r '.local.url' "${project_dir}/${wp_move_file}")
    local_path=$(jq -r '.local.path' "${project_dir}/${wp_move_file}")
    local_backup=$(jq -r '.local.backup' "${project_dir}/${wp_move_file}")
    local_wpcli=$(jq -r '.local.wpcli' "${project_dir}/${wp_move_file}")
    local_db_host=$(jq -r '.local.db.host' "${project_dir}/${wp_move_file}")
    local_db_name=$(jq -r '.local.db.name' "${project_dir}/${wp_move_file}")
    local_db_user=$(jq -r '.local.db.user' "${project_dir}/${wp_move_file}")
    local_db_pass=$(jq -r '.local.db.pass' "${project_dir}/${wp_move_file}")
    prod_protocol=$(jq -r '.prod.protocol' "${project_dir}/${wp_move_file}")
    prod_url=$(jq -r '.prod.url' "${project_dir}/${wp_move_file}")
    prod_path=$(jq -r '.prod.path' "${project_dir}/${wp_move_file}")
    prod_host=$(jq -r '.prod.host' "${project_dir}/${wp_move_file}")
    prod_user=$(jq -r '.prod.user' "${project_dir}/${wp_move_file}")
    prod_password=$(jq -r '.prod.password' "${project_dir}/${wp_move_file}")
    prod_port=$(jq -r '.prod.port' "${project_dir}/${wp_move_file}")
    # prod_passphrase=$(jq -r '.prod.passphrase' "${project_dir}/${wp_move_file}")
    # prod_privateKeyPath=$(jq -r '.prod.privateKeyPath' "${project_dir}/${wp_move_file}")
    prod_wpcli=$(jq -r '.prod.wpcli' "${project_dir}/${wp_move_file}")
    prod_db_tool=$(jq -r '.prod.db.tool' "${project_dir}/${wp_move_file}")
    prod_db_options=$(jq -r '.prod.db.options' "${project_dir}/${wp_move_file}")

    verify_param name
    verify_param local_url
    verify_param local_path
    verify_param local_backup
    verify_param local_wpcli
    verify_param local_db_host
    verify_param local_db_name
    verify_param local_db_user
    verify_param local_db_pass    
    verify_param prod_protocol
    verify_param prod_url
    verify_param prod_path
    verify_param prod_host
    verify_param prod_user
    verify_param prod_port
    verify_param prod_db_tool
    verify_param prod_db_options

    wp_abspath="${project_dir}/${local_path}"
    backup_dir="${project_dir}/${local_backup}"
}

verify_param() {
	if [ -z "${!1}" ]; then
        error
		printf "%s value not present in %s, exiting...\n" "${1}" "${wp_move_file}"
		exit 1
	fi
}

error() {
    printf '\033[1;31m%-6s\033[0m' 'Error: '
}

create_lock_file() {
    ## catching Ctrl+C
    trap remove_lock_file SIGINT SIGTERM

    if [ -e "${project_dir}/${lock_file}" ]; then
        error
        printf "File lock found, another instance is running?"
        exit 1
    fi

    touch "${project_dir}/${lock_file}" || {
        error
        printf "Cannot create lock file - exiting..."
        exit 1
    }
}

remove_lock_file() {
	if [ -e "${project_dir}/${lock_file}" ]; then
		rm -f "${project_dir}/${lock_file}" || { 
            error
			printf "Cannot remove lock file: %s" "${project_dir}/${lock_file}"
			exit 1
		}
	fi
}

help() {

    printf "\nUsage: wp-move [OPTION]\n\n"
    printf "Options (when no option is provided, then we do first 3 steps listed below)\n"
    printf " --files    sync files\n"
    printf " --config   generate wp-config.php file\n"
    printf " --db       sync database\n"
    printf " --init     generate wp-move.yml configuration file\n"
    printf " --php      print remote host php version\n"
    printf " --unlock   delete lock file\n"
    printf " --help     show this help\n\n"
}

php_version() {

    version=$(ssh "${prod_user}@${prod_host}" -p "$prod_port" /bin/bash << REMOTE_CMD
            php -r "echo PHP_VERSION;" | grep --only-matching --perl-regexp "7.\d+"
REMOTE_CMD
        )
    printf "%s\n" "${version}"
}

# Main functions

download_files() {

    if [ "$prod_protocol" = "ssh" ]; then
        # TODO - when ssh agent is not runing
        if [ -r "${project_dir}/${wp_move_ignore}" ]; then
            rsync -rlpcP --exclude-from "${project_dir}/${wp_move_ignore}" -e "ssh -p $prod_port" "$prod_user"@"$prod_host":"$prod_path" "$wp_abspath"
        else
            rsync -rlpcP -e "ssh -p $prod_port" "$prod_user"@"$prod_host":"$prod_path" "$wp_abspath"
        fi

    elif [ "$prod_protocol" = "ftp" ]; then

        # TODO check if is lftp installed
        verify_param prod_password
        LFTP_PASSWORD=$prod_password
        export LFTP_PASSWORD

        if [ -r "${project_dir}/${wp_move_ignore}" ]; then
            lftp -e "set ssl:verify-certificate/$prod_host no; mirror --only-newer --no-perms --exclude-glob-from=${project_dir}/${wp_move_ignore} --verbose --use-pget-n=8 -c $prod_path $wp_abspath; quit" -p "$prod_port" --env-password -u "$prod_user" "$prod_host"
        else
            lftp -e "set ssl:verify-certificate/$prod_host no; mirror --only-newer --no-perms --verbose --use-pget-n=8 -c $prod_path $wp_abspath; quit" -p "$prod_port" --env-password -u "$prod_user" "$prod_host"
        fi
        # FIXME - verify-certificate no - not secure
    fi
}

export_db() {

    if [ "$prod_protocol" = "ssh" ]; then

        if [ "$prod_db_tool" = "wpcli" ]; then

            if [ -z "$prod_wpcli" ]; then

                ssh "${prod_user}@${prod_host}" -p "$prod_port" /bin/bash << 'REMOTE_CMD'
                    if ! [ -s ${prod_path}/wp-cli.phar ]; then
                        cd $prod_path
                        curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
                    fi
REMOTE_CMD
                prod_wpcli="php ${prod_path}/wp-cli.phar"
            fi

            ssh "${prod_user}@${prod_host}" -p "$prod_port" "${prod_wpcli} db export - --path=${prod_path} ${prod_db_options}" > "${backup_dir}/${name}-${todays_date}.sql"
                # TODO - not sure we want to delete wp-cli.phar every time and download it again? wp-cli.phar living in root dir shouldn't be a problem
                # ssh "${prod_user}@${prod_host}" -p "$prod_port" "rm ${prod_path}/wp-cli.phar"

        elif [ "$prod_db_tool" = "mysqldump" ]; then
            # TODO - implement mysqldump
            error
            printf "prod_db_tool: mysqldump not implemented"
            remove_lock_file
            exit 1
        fi

    elif [ "$prod_protocol" = "ftp" ]; then # wersja bez dostępu do ssh 

        # TODO improve wp-dump.php script
        lftp -e "set ssl:verify-certificate/$prod_host no; put -O $prod_path $move_script_dir/.wp-move.sh/wp-dump.php; quit" -p "$prod_port" --env-password -u "$prod_user" "$prod_host"
        wget -O "${backup_dir}/${name}-${todays_date}.sql" "${prod_url}/wp-dump.php"
        lftp -e "set ssl:verify-certificate/$prod_host no; rm $prod_path/wp-dump.php; quit" -p "$prod_port" --env-password -u "$prod_user" "$prod_host"
    fi
}

import_db() {

    ${local_wpcli} db create --quiet || true > /dev/null
    ${local_wpcli} db import "${backup_dir}/${name}-${todays_date}.sql" || {
        error
        printf "DB import failed"
        remove_lock_file
        exit 1
    }

    ## https://stackoverflow.com/a/45521875
    pattern='^(([[:alnum:]]+)://)?(([[:alnum:]]+)@)?([^:^@]+)(:([[:digit:]]+))?$'
    if [[ "$prod_url" =~ $pattern ]]; then
        prod_url_no_protocol=${BASH_REMATCH[5]}
    fi
    if [[ "$local_url" =~ $pattern ]]; then
        local_url_no_protocol=${BASH_REMATCH[5]}
    fi

    ${local_wpcli} search-replace "$prod_url" "$local_url" --quiet
    ${local_wpcli} search-replace "$prod_url_no_protocol" "$local_url_no_protocol" --quiet
}

setup_wp_config() {

    # making sure we backed up wp-config.php
    if [ ! -s "${backup_dir}/wp-config.php" ]; then
        cp "${wp_abspath}/wp-config.php" "${backup_dir}/wp-config.php"
        # add to wp_move_ignore
        cat "wp-config.php" >> "${project_dir}/${wp_move_ignore}"
    fi

    table_prefix=$(${local_wpcli} config get table_prefix)
    db_charset=$(${local_wpcli} config get DB_CHARSET)
    db_collate=$(${local_wpcli} config get DB_COLLATE)

    if [ -s "${project_dir}/${wp_config_extra}" ]; then
        # we don't need first line ( <?php )
        wp_config_extra=$(tail -n +2 "${project_dir}/${wp_config_extra}")
        ${local_wpcli} config create --dbname="${local_db_name}" --dbuser="${local_db_user}" --dbpass="${local_db_pass}" --dbhost="${local_db_host}" --dbprefix="${table_prefix}" --dbcharset="${db_charset}" --dbcollate="${db_collate}" --skip-check --force --extra-php <<EXTRA_PHP
    $wp_config_extra

EXTRA_PHP
    else
        ${local_wpcli} config create --dbname="${local_db_name}" --dbuser="${local_db_user}" --dbpass="${local_db_pass}" --dbhost="${local_db_host}" --dbprefix="${table_prefix}" --dbcharset="${db_charset}" --dbcollate="${db_collate}" --skip-check --force
    fi
}

init() {

    overwrite_move_file='y'
    # if there is wp-move.yml file, make sure we want to overwrite it
    if [ -e "${project_dir}/${wp_move_file}" ]; then
        read -r -p "You already have ${wp_move_file} file, are You sure You want to overwrite it? (y/N) " overwrite_move_file
    fi

    case "$overwrite_move_file" in
        [Yy]* ) 
            cp "${move_script_dir}/.wp-move.sh/templates/${wp_move_file}" "${project_dir}/${wp_move_file}"
            # read -p "Some question about wp-move.yml config file?" some_var
            sed -i "s/%PROJECT_NAME%/${project_name}/" "${project_dir}/${wp_move_file}"
            # nano "${project_dir}/${wp_move_file}"
            printf "%s file initialized\n" "${wp_move_file}"
    esac
    overwrite_move_ignore='y'
    # if there is wp-move.yml file, make sure we want to overwrite it
    if [ -e "${project_dir}/${wp_move_ignore}" ]; then
        read -r -p "You already have ${wp_move_ignore} file, are You sure You want to overwrite it? (y/N) " overwrite_move_ignore
    fi

    case "$overwrite_move_ignore" in
        [Yy]* ) 
            cp "${move_script_dir}/.wp-move.sh/templates/${wp_move_ignore}" "${project_dir}/${wp_move_ignore}"
            printf "%s file initialized\n" "${wp_move_ignore}"
    esac
    overwrite_config_extra='y'
    # if there is wp-move.yml file, make sure we want to overwrite it
    if [ -e "${project_dir}/${wp_config_extra}" ]; then
        read -r -p "You already have ${wp_config_extra} file, are You sure You want to overwrite it? (y/N) " overwrite_config_extra
    fi

    case "$overwrite_config_extra" in
        [Yy]* ) 
            cp "${move_script_dir}/.wp-move.sh/templates/${wp_config_extra}" "${project_dir}/${wp_config_extra}"
            printf "%s file initialized\n" "${wp_config_extra}"
            return ;;
        * ) 
            printf "OK, bye\n"
            return;;
    esac
}
# end functions 

if [ -n "$1" ]; then

    case "$1" in 
    --files)
        parse_config
        create_lock_file
        download_files;;
    --db)
        parse_config
        create_lock_file
        export_db
        setup_wp_config
        import_db;;
    --config)
        parse_config
        create_lock_file
        setup_wp_config;;
    --deploy)
        deploy;;
    --help)
        help
        exit;;
    --init)
        init
        exit;;
    --php)
        parse_config
        php_version
        exit;;
    --unlock)
        remove_lock_file
        exit;;
    **)
        help
        exit;;
    esac
else
    parse_config
    create_lock_file
    download_files
    export_db
    setup_wp_config
    import_db
fi

remove_lock_file